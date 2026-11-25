// Workspace project & tag classification, silent project-creation proposals, and cross-station
// lightweight RPC handlers (`projects.names`, `thread.classify`).
import { presetProjectsOf } from "../../../client/core-ts/src/preset-records.ts";
import { randomUUID } from "node:crypto";
import { stat } from "node:fs/promises";
import { Refused as HttpRefused } from "../api/request.ts";
import { Refused } from "../jobs/remote.ts";
import { stationLang } from "../ops/i18n.ts";
import {
  ensureProjectRegistered,
  normalizeNote,
  normalizeRefs,
  projectsInfoPath,
  pruneAppliedOpIds,
  readProjectsInfoBestEffort,
  renameProjectInfo,
  stripInternalProjectInfo,
  updateProjectInfo,
} from "../projects/info.ts";
import {
  MAX_THREAD_TAGS,
  type ProjectProposal,
  STILLFAIL_SURFACE,
  type SessionThread,
  type ThreadRow,
  normalizeProject,
  normalizeTags,
} from "../store/rows.ts";
import type { Args } from "./args.ts";
import { hasProposalMarker, isNotice, markNotice } from "./chat.ts";
export { hasProposalMarker };
import type { Hub } from "./hub.ts";
import { elsewhere, fromBefore, linkedSession, named, peersOf, scopeOf, sessionThreadOf, threadIn } from "./others.ts";
import { threadAddress } from "../agents/instructions.ts";

type Json = any;

export const PROJECTS_NAMES = "projects.names";
export const THREAD_CLASSIFY = "thread.classify";

const MAX_HEADER_BYTES = 1024;
const PEER_CACHE_TTL_MS = 60_000;
const INFO_STAT_TTL_MS = 10_000;

export type ProjectsToldState = {
  names: Set<string>;
  tags: Set<string>;
};

export type ClassificationInput = {
  project?: string;
  tags?: string[];
  tagsAdd?: string[];
  tagsRemove?: string[];
};

export function hasClassificationArgs(args: Args): boolean {
  return args.project !== undefined || args.tags !== undefined || args.tags_add !== undefined || args.tags_remove !== undefined;
}

export function parseClassificationArgs(args: Args): ClassificationInput {
  const out: ClassificationInput = {};
  if (args.project !== undefined) {
    if (typeof args.project !== "string") throw new Error("project must be a string (use \"\" for cross-project)");
    out.project = normalizeProject(args.project);
  }
  if (args.tags !== undefined) {
    if (!Array.isArray(args.tags)) throw new Error("tags must be an array of strings");
    out.tags = normalizeTags(args.tags, true);
  }
  if (args.tags_add !== undefined) {
    if (!Array.isArray(args.tags_add)) throw new Error("tags_add must be an array of strings");
    out.tagsAdd = normalizeTags(args.tags_add, true);
  }
  if (args.tags_remove !== undefined) {
    if (!Array.isArray(args.tags_remove)) throw new Error("tags_remove must be an array of strings");
    out.tagsRemove = args.tags_remove.filter((x): x is string => typeof x === "string").map((s) => s.trim()).filter((s) => s !== "");
  }
  if (out.tags !== undefined && (out.tagsAdd !== undefined || out.tagsRemove !== undefined)) {
    throw new Error("cannot combine tags with tags_add or tags_remove");
  }
  return out;
}

function assertProjectsEnabled(hub: Hub): void {
  if (!hub.projectsOn()) {
    throw new HttpRefused(403, "chat classification is not enabled on this station");
  }
}

function assertCallerWorkspaceAllowed(hub: Hub, key: string): string {
  if (!hub.canActInWorkspace(key)) {
    throw new Error("this station cannot run project actions for this chat's workspace (unbound, left workspace, retiring, or rig-only)");
  }
  const effectiveWs = scopeOf(hub, key) ?? hub.homeWorkspace();
  if (effectiveWs === null || effectiveWs === "") {
    throw new Error("this station is not bound to a workspace: project actions require an active workspace");
  }
  return effectiveWs;
}

/// Resolves a `chat` reference directly to a logical `ThreadRow` on this station (supporting multi-agent threads).
export function resolveThreadHere(hub: Hub, chat: string, ws: string | null, caller: string | null): ThreadRow {
  const effectiveWs = ws ?? hub.homeWorkspace();
  const ref = chat.trim();
  if (ref === "" || ref.toLowerCase() === "self") {
    if (caller === null) throw new Error("chat is required");
    const st = hub.store.latestThread(caller);
    if (!st) throw new Error("this session has no conversation thread yet");
    return st.thread;
  }
  const clean = ref.includes("/o/") || ref.includes("/chats/") ? ref.split("?")[0]! : ref;
  const what = named(hub, clean, effectiveWs);
  if (what.type === "thread") {
    if (!threadIn(hub, what.thread, effectiveWs)) {
      throw new Error("that chat is in another workspace: only this workspace's chats can be classified");
    }
    return what.thread;
  }
  if (effectiveWs !== null && !hub.inWorkspace(what.key, effectiveWs)) {
    throw new Error("that chat is in another workspace: only this workspace's chats can be classified");
  }
  try {
    return sessionThreadOf(hub, what.key).thread;
  } catch {
    const st = hub.store.latestThread(what.key);
    if (!st) throw new Error(`session ${what.key} has no conversation thread`);
    return st.thread;
  }
}

/// Applies classification changes silently to a local thread (no notice posted).
export function applyClassificationHere(hub: Hub, thread: ThreadRow, input: ClassificationInput): { thread: ThreadRow; changed: boolean } {
  let nextTags: string[] | undefined;
  if (input.tags !== undefined) {
    nextTags = input.tags;
  } else if (input.tagsAdd !== undefined || input.tagsRemove !== undefined) {
    const remove = new Set(input.tagsRemove ?? []);
    const cur = (thread.tags ?? []).filter((t) => !remove.has(t));
    for (const add of input.tagsAdd ?? []) {
      if (!cur.includes(add)) {
        if (cur.length >= MAX_THREAD_TAGS) {
          throw new Error(`at most ${MAX_THREAD_TAGS} tags are allowed`);
        }
        cur.push(add);
      }
    }
    nextTags = cur;
  }
  return hub.store.setThreadClassification(thread.id, {
    ...(input.project !== undefined ? { project: input.project } : {}),
    ...(nextTags !== undefined ? { tags: nextTags } : {}),
    force: false,
  });
}

export function isUnsupportedError(msg: string): boolean {
  return fromBefore(msg) || /unknown.*method|unsupported.*method/i.test(msg);
}

function isRigRefusal(msg: string): boolean {
  return /a rig does not (answer|serve)/i.test(msg);
}

/// Fetches online peer project names for workspace `ws` (using Hub's 60s TTL cache).
/// Works both with a session key (`peersOf`) and without one (`hub.peersInWorkspace`, for `classifyForPeer`).
async function fetchPeerProjectNames(hub: Hub, key: string | null, ws: string | null): Promise<string[]> {
  const call = key !== null ? peersOf(hub, key) : hub.peersInWorkspace(ws);
  if (!call) return [];
  const roster = await call("", { method: "peers" }).catch(() => null);
  const selfId = hub.station() ?? "";
  const stations: { id: string; name?: string; online?: boolean }[] = Array.isArray(roster?.stations) ? roster.stations : [];
  const peers = stations.filter((s) => typeof s?.id === "string" && s.id !== "" && s.id !== selfId && s.online !== false);
  const names = new Set<string>();
  await Promise.all(peers.map(async (p) => {
    try {
      const res = await call(p.id, { method: PROJECTS_NAMES });
      if (Array.isArray(res?.projects)) {
        for (const item of res.projects) {
          if (typeof item?.name === "string" && item.name !== "") names.add(item.name);
        }
      }
    } catch {
      // Best-effort peer lookup for hints / known-set augmentation.
    }
  }));
  return [...names].sort();
}

async function peerProjectNames(hub: Hub, key: string | null, ws: string | null): Promise<string[]> {
  const wsKey = ws ?? hub.homeWorkspace() ?? "";
  const now = hub.store.now();
  const cached = hub.getPeerProjectsCache(wsKey, now, PEER_CACHE_TTL_MS);
  if (cached !== null) return cached;
  const list = await fetchPeerProjectNames(hub, key, ws);
  hub.setPeerProjectsCache(wsKey, now, list);
  return list;
}

/// Returns the known project names in workspace `ws` (local active unhidden threads + `PROJECTS.jsonl` + online full peers).
export async function knownWorkspaceProjects(hub: Hub, key: string | null, ws: string | null): Promise<Set<string>> {
  const home = hub.homeWorkspace();
  const local = hub.store.workspaceProjectNames(ws, home, 500);
  const info = await readProjectsInfoBestEffort(hub.config().agentHome, ws, home, { skipPrivate: key === null });
  const known = new Set<string>(local.projects.map((p) => p.name));
  for (const name of Object.keys(info.projects)) known.add(name);
  const fromPeers = await peerProjectNames(hub, key, ws);
  for (const name of fromPeers) known.add(name);
  return known;
}

async function peerHasProject(
  hub: Hub,
  key: string | null,
  ws: string | null,
  project: string,
  opts?: { offlineIsUncertain?: boolean },
): Promise<{ exists: boolean; uncertain?: string }> {
  const call = key !== null ? peersOf(hub, key) : hub.peersInWorkspace(ws);
  if (!call) return { exists: false };
  let roster: Json = null;
  try {
    roster = await call("", { method: "peers" });
  } catch (e) {
    return { exists: false, uncertain: `peer roster lookup failed: ${(e as Error).message}` };
  }
  const selfId = hub.station() ?? "";
  const stations: { id: string; name?: string; online?: boolean }[] = Array.isArray(roster?.stations) ? roster.stations : [];
  const otherStations = stations.filter((s) => typeof s?.id === "string" && s.id !== "" && s.id !== selfId);
  let found = false;
  let uncertain: string | undefined;
  if (opts?.offlineIsUncertain === true) {
    for (const p of otherStations) {
      if (p.online === false) {
        uncertain ??= `peer ${p.id} is offline`;
      }
    }
  }
  const peers = otherStations.filter((s) => s.online !== false);
  await Promise.all(peers.map(async (p) => {
    if (found) return;
    try {
      const res = await call(p.id, { method: PROJECTS_NAMES, check: project });
      if (res?.exists === true) {
        found = true;
        return;
      }
      // Graceful fallback for older peers that ignore `check` and return `{ projects: [...] }`.
      if (res?.exists === undefined && Array.isArray(res?.projects)) {
        if (res.projects.some((item: Json) => item?.name === project)) found = true;
      }
    } catch (e) {
      const msg = (e as Error).message;
      // Ignore rig refusals and legacy unsupported peers; record real reachability/RPC failures as uncertain.
      if (!isRigRefusal(msg) && !(e instanceof Refused && isUnsupportedError(msg))) {
        uncertain ??= `peer ${p.id} lookup failed: ${msg}`;
      }
    }
  }));
  return { exists: found, ...(uncertain !== undefined ? { uncertain } : {}) };
}

async function isKnownProject(
  hub: Hub,
  key: string | null,
  ws: string | null,
  project: string,
  opts?: { fresh?: boolean; skipPrivate?: boolean; strictPeer?: boolean; offlineIsUncertain?: boolean },
): Promise<boolean> {
  if (project === "") return true;
  const home = hub.homeWorkspace();
  // O(log N) indexed existence check on local active unhidden threads first (never truncated by cap).
  if (hub.store.hasActiveProjectInWorkspace(ws, home, project)) return true;
  // Next check local PROJECTS.jsonl (skipPrivate when invoked by a peer so 0600 private entries are not leaked).
  const info = await readProjectsInfoBestEffort(hub.config().agentHome, ws, home, { skipPrivate: opts?.skipPrivate ?? (key === null) });
  if (Object.hasOwn(info.projects, project)) return true;
  // Fast hit from peer cache if warm and not requiring an authoritative fresh check.
  if (opts?.fresh !== true) {
    const wsKey = ws ?? home ?? "";
    const cached = hub.getPeerProjectsCache(wsKey, hub.store.now(), PEER_CACHE_TTL_MS);
    if (cached !== null && cached.includes(project)) return true;
  }
  // Exact single-name peer check (unbounded by 200-item list cap, works on cold cache too).
  const peer = await peerHasProject(hub, key, ws, project, { offlineIsUncertain: opts?.offlineIsUncertain });
  if (peer.exists) return true;
  if (opts?.strictPeer === true && peer.uncertain !== undefined) {
    throw new HttpRefused(503, `cannot verify whether project ${JSON.stringify(project)} exists on peers (${peer.uncertain}); retry when peers are reachable`);
  }
  return false;
}

async function assertKnownProject(
  hub: Hub,
  key: string | null,
  ws: string | null,
  project: string,
  opts?: { fresh?: boolean; skipPrivate?: boolean; strictPeer?: boolean; offlineIsUncertain?: boolean },
): Promise<void> {
  if (await isKnownProject(hub, key, ws, project, { ...opts, strictPeer: opts?.strictPeer ?? false })) return;
  throw new HttpRefused(404, `unknown project ${JSON.stringify(project)}: agents cannot create new projects directly — use project_manage(action="propose") to propose it, or pick an existing project`);
}

/// Classifies a local or cross-station chat (called by `chat_configure` when only classification params are given).
export async function classifyChat(hub: Hub, key: string, chatRaw: string, input: ClassificationInput): Promise<string> {
  assertProjectsEnabled(hub);
  const ws = assertCallerWorkspaceAllowed(hub, key);
  if (input.project !== undefined && input.project !== "") {
    await assertKnownProject(hub, key, ws, input.project);
  }
  const chat = chatRaw.trim();
  const self = chat === "" || chat.toLowerCase() === "self";
  let station = self ? null : elsewhere(hub, key, chat);
  let targetChat = chat;
  if (!self && station === null) {
    const ref = linkedSession(chat)?.[0] ?? chat;
    const moved = hub.store.handedTo(ref);
    if (moved !== null) {
      station = moved.station;
      targetChat = ref;
    }
  }
  if (station === null) {
    const thread = resolveThreadHere(hub, targetChat, ws, key);
    const res = applyClassificationHere(hub, thread, input);
    return JSON.stringify({
      updated: res.changed,
      thread: res.thread.id,
      project: res.thread.project ?? null,
      projectLocked: res.thread.projectLocked === true,
      tags: res.thread.tags ?? [],
    });
  }
  const call = peersOf(hub, key);
  if (!call) throw new Error("other stations cannot be reached from this one yet");
  try {
    const answer = await call(station, {
      method: THREAD_CLASSIFY,
      session: key,
      chat: targetChat,
      ...(input.project !== undefined ? { project: input.project } : {}),
      ...(input.tags !== undefined ? { tags: input.tags } : {}),
      ...(input.tagsAdd !== undefined ? { tags_add: input.tagsAdd } : {}),
      ...(input.tagsRemove !== undefined ? { tags_remove: input.tagsRemove } : {}),
    });
    return JSON.stringify(answer);
  } catch (error) {
    const why = (error as Error).message;
    if (error instanceof Refused && isUnsupportedError(why)) {
      throw new Error(`station ${station} does not support chat classification yet (needs update)`);
    }
    throw new Error(`classify request to station ${station} failed: ${why}`);
  }
}

/// Mesh RPC handler: `projects.names`.
/// When `check` is given, performs an exact O(log N) existence check (never truncated by the 200-item list cap).
/// Otherwise returns bounded active project/tag counts + shared non-private PROJECTS.jsonl names in `ws`.
export async function projectNamesForPeer(
  hub: Hub,
  ws: string | null,
  check?: string,
): Promise<{ exists: boolean } | { projects: { name: string; count: number; countCapped?: boolean }[]; tags: { name: string; count: number; countCapped?: boolean }[] }> {
  const effectiveWs = ws ?? hub.homeWorkspace();
  if (hub.isRigIn(effectiveWs)) throw new Refused(`a rig does not answer ${PROJECTS_NAMES}`);
  const home = hub.homeWorkspace();
  if (typeof check === "string" && check.trim() !== "") {
    let normalized: string;
    try {
      normalized = normalizeProject(check);
    } catch {
      return { exists: false };
    }
    if (normalized === "") return { exists: false };
    if (hub.store.hasActiveProjectInWorkspace(effectiveWs, home, normalized)) return { exists: true };
    const info = await readProjectsInfoBestEffort(hub.config().agentHome, effectiveWs, home, { skipPrivate: true });
    return { exists: normalized in info.projects };
  }
  const local = hub.store.workspaceProjectNames(effectiveWs, home, 200);
  // skipPrivate: true ensures 0600 private PROJECTS.jsonl never leaks to peers.
  const info = await readProjectsInfoBestEffort(hub.config().agentHome, effectiveWs, home, { skipPrivate: true });
  const byName = new Map(local.projects.map((p) => [p.name, { count: p.count, capped: p.countCapped === true }]));
  for (const name of Object.keys(info.projects)) {
    if (!byName.has(name)) byName.set(name, { count: 0, capped: false });
  }
  const projects = [...byName.entries()]
    .sort((a, b) => b[1].count - a[1].count || (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0))
    .slice(0, 200)
    .map(([name, v]) => ({ name, count: v.count, ...(v.capped ? { countCapped: true } : {}) }));
  return { projects, tags: local.tags };
}

/// Forward-resolves `startName` through causal rename events `(renamedAt, originSeq, seq)` so out-of-order peer
/// deliveries and late `pending_info` retries converge to the final target name and carry the final event watermark.
function forwardResolveTarget(
  events: readonly { seq: number; from: string; to: string; renamedAt: number; wallAt?: number; originSeq: number; opId: string | null }[],
  startName: string,
  startAt: number,
  startOriginSeq: number,
  selfOpId: string | null,
  startWallAt: number = startAt,
): { target: string; advanced: boolean; at: number; wallAt: number; originSeq: number; seq: number } {
  let cur = startName;
  let curAt = startAt;
  let curWallAt = startWallAt;
  let curOriginSeq = startOriginSeq;
  let curSeq = 0;
  let advanced = false;
  if (cur === "") return { target: cur, advanced, at: curAt, wallAt: curWallAt, originSeq: curOriginSeq, seq: curSeq };
  for (const ev of events) {
    if (selfOpId !== null && ev.opId === selfOpId) continue;
    if (ev.from === cur && (ev.renamedAt > curAt || (ev.renamedAt === curAt && ev.originSeq > curOriginSeq))) {
      cur = ev.to;
      curAt = ev.renamedAt;
      curWallAt = ev.wallAt ?? ev.renamedAt;
      curOriginSeq = ev.originSeq;
      curSeq = ev.seq;
      advanced = true;
      if (cur === "") break;
    }
  }
  return { target: cur, advanced, at: curAt, wallAt: curWallAt, originSeq: curOriginSeq, seq: curSeq };
}

/// Mesh RPC handler: `thread.classify` (single thread classification or bulk project rename/merge in `ws`).
export async function classifyForPeer(hub: Hub, request: Json, ws: string | null): Promise<Json> {
  const effectiveWs = ws ?? hub.homeWorkspace();
  if (!hub.projectsOn()) throw new Refused(`unknown peer method ${THREAD_CLASSIFY}`);
  if (hub.isRigIn(effectiveWs)) throw new Refused(`a rig does not answer ${THREAD_CLASSIFY}`);
  if (effectiveWs !== null && hub.quietIn(effectiveWs)) throw new Refused("this station is retiring from this workspace");
  if (request?.rename && typeof request.rename === "object") {
    if (typeof request.rename.from !== "string" || typeof request.rename.to !== "string") {
      throw new Error("rename.from and rename.to must be strings");
    }
    const home = hub.homeWorkspace();
    const wsKey = effectiveWs ?? home ?? "";
    const from = normalizeProject(request.rename.from);
    const to = normalizeProject(request.rename.to);
    const opId = typeof request.rename.opId === "string" && request.rename.opId.trim() !== "" ? request.rename.opId.trim() : null;
    const incomingRenamedAt =
      typeof request.rename.renamedAt === "number" && Number.isFinite(request.rename.renamedAt)
        ? request.rename.renamedAt
        : hub.store.now();
    const incomingWallAt =
      typeof request.rename.wallAt === "number" && Number.isFinite(request.rename.wallAt)
        ? request.rename.wallAt
        : incomingRenamedAt;
    const incomingOriginSeq =
      typeof request.rename.originSeq === "number" && Number.isFinite(request.rename.originSeq)
        ? request.rename.originSeq
        : 0;

    return withWorkspaceRenameLock(hub, wsKey, async () => {
      const events = hub.store.listProjectRenameEvents(wsKey);
      const resolved = forwardResolveTarget(events, to, incomingRenamedAt, incomingOriginSeq, opId, incomingWallAt);
      const committed = hub.store.commitLocalProjectRenameAtomic({
        ws: effectiveWs,
        home,
        action: request.rename.action === "merge" ? "merge" : "rename",
        from,
        to,
        effectiveTo: resolved.target,
        ...(resolved.advanced
          ? { effectiveWatermark: { at: resolved.at, wallAt: resolved.wallAt, originSeq: resolved.originSeq, seq: resolved.seq } }
          : {}),
        renamedAt: incomingRenamedAt,
        wallAt: incomingWallAt,
        originSeq: incomingOriginSeq,
        opKey: null,
        opId,
        pendingPeers: [],
        pendingRoster: false,
        pendingInfo: false,
      });
      for (const [wk, sub] of committed.presetNotifies) hub.notifyPresetProjectsChanged(wk, sub);
      return committed.local;
    });
  }
  const chat = typeof request?.chat === "string" ? request.chat.trim() : "";
  if (chat === "") throw new Error("chat is required");
  const input = parseClassificationArgs(request ?? {});
  if (input.project !== undefined && input.project !== "") {
    await assertKnownProject(hub, null, effectiveWs, input.project);
  }
  const thread = resolveThreadHere(hub, chat, effectiveWs, null);
  const res = applyClassificationHere(hub, thread, input);
  return {
    updated: res.changed,
    thread: res.thread.id,
    project: res.thread.project ?? null,
    projectLocked: res.thread.projectLocked === true,
    tags: res.thread.tags ?? [],
  };
}

/// Queries all online full stations in the caller's workspace for `projects.names` and merges with local + `PROJECTS.jsonl`.
export async function collectWorkspaceProjects(hub: Hub, key: string): Promise<{
  projects: { name: string; count: number; countCapped?: boolean; note?: string; refs?: string[] }[];
  tags: { name: string; count: number; countCapped?: boolean }[];
  peers: { station: string; name?: string; status: "ok" | "offline" | "unsupported" | "rig" | "error"; error?: string }[];
}> {
  const ws = assertCallerWorkspaceAllowed(hub, key);
  const home = hub.homeWorkspace();
  const local = hub.store.workspaceProjectNames(ws, home, 200);
  const info = await readProjectsInfoBestEffort(hub.config().agentHome, ws, home);

  const projectCounts = new Map<string, number>();
  const projectCapped = new Set<string>();
  const tagCounts = new Map<string, number>();
  const tagCapped = new Set<string>();
  for (const p of local.projects) {
    projectCounts.set(p.name, (projectCounts.get(p.name) ?? 0) + p.count);
    if (p.countCapped) projectCapped.add(p.name);
  }
  for (const t of local.tags) {
    tagCounts.set(t.name, (tagCounts.get(t.name) ?? 0) + t.count);
    if (t.countCapped) tagCapped.add(t.name);
  }
  for (const name of Object.keys(info.projects)) {
    if (!projectCounts.has(name)) projectCounts.set(name, 0);
  }

  const peerReport: { station: string; name?: string; status: "ok" | "offline" | "unsupported" | "rig" | "error"; error?: string }[] = [];
  const peerNames = new Set<string>();
  const call = peersOf(hub, key);
  if (call) {
    const roster = await call("", { method: "peers" }).catch(() => null);
    const selfId = hub.station() ?? "";
    const stations: { id: string; name?: string; online?: boolean }[] = Array.isArray(roster?.stations) ? roster.stations : [];
    const peers = stations.filter((s) => typeof s?.id === "string" && s.id !== "" && s.id !== selfId);
    await Promise.all(peers.map(async (p) => {
      if (p.online === false) {
        peerReport.push({ station: p.id, ...(p.name ? { name: p.name } : {}), status: "offline" });
        return;
      }
      try {
        const res = await call(p.id, { method: PROJECTS_NAMES });
        if (Array.isArray(res?.projects)) {
          for (const item of res.projects) {
            if (typeof item?.name === "string" && item.name !== "" && typeof item?.count === "number") {
              projectCounts.set(item.name, (projectCounts.get(item.name) ?? 0) + item.count);
              if (item.countCapped === true) projectCapped.add(item.name);
              peerNames.add(item.name);
            }
          }
        }
        if (Array.isArray(res?.tags)) {
          for (const item of res.tags) {
            if (typeof item?.name === "string" && item.name !== "" && typeof item?.count === "number") {
              tagCounts.set(item.name, (tagCounts.get(item.name) ?? 0) + item.count);
              if (item.countCapped === true) tagCapped.add(item.name);
            }
          }
        }
        peerReport.push({ station: p.id, ...(p.name ? { name: p.name } : {}), status: "ok" });
      } catch (e) {
        const msg = (e as Error).message;
        if (isRigRefusal(msg)) {
          peerReport.push({ station: p.id, ...(p.name ? { name: p.name } : {}), status: "rig" });
        } else if (e instanceof Refused && isUnsupportedError(msg)) {
          peerReport.push({ station: p.id, ...(p.name ? { name: p.name } : {}), status: "unsupported" });
        } else if (/timed out|offline|not connected|unreachable|PeerGone/i.test(msg)) {
          peerReport.push({ station: p.id, ...(p.name ? { name: p.name } : {}), status: "offline", error: msg });
        } else {
          peerReport.push({ station: p.id, ...(p.name ? { name: p.name } : {}), status: "error", error: msg });
        }
      }
    }));
    hub.setPeerProjectsCache(ws ?? home ?? "", hub.store.now(), [...peerNames].sort());
  }

  const projects = [...projectCounts.entries()]
    .sort((a, b) => b[1] - a[1] || (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0))
    .map(([name, count]) => {
      const meta = info.projects[name];
      return {
        name,
        count,
        ...(projectCapped.has(name) ? { countCapped: true } : {}),
        ...(meta?.note ? { note: meta.note } : {}),
        ...(meta?.refs && meta.refs.length > 0 ? { refs: meta.refs } : {}),
      };
    });
  const tags = [...tagCounts.entries()]
    .sort((a, b) => b[1] - a[1] || (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0))
    .map(([name, count]) => ({ name, count, ...(tagCapped.has(name) ? { countCapped: true } : {}) }));

  return { projects, tags, peers: peerReport };
}

/// Builds a compact (<= 1 KB, JSON-escaped) `<workspace-projects>` delta header for session `key`.
/// NEVER awaits cross-station peer RPCs on the message delivery hot path: uses local DB + `PROJECTS.jsonl` +
/// currently cached peer names, triggering a deduplicated background refresh on cache miss/expiry.
/// Tracks emitted project names AND emitted tags individually so truncated items are delivered on subsequent turns.
export async function formatWorkspaceProjectsDelta(
  hub: Hub,
  key: string,
  toldMap: Map<string, ProjectsToldState>,
): Promise<{ text: string; markTold: () => void } | null> {
  if (!hub.projectsOn()) return null;
  const ws = hub.wsOf(key);
  const home = hub.homeWorkspace();
  const wsKey = ws ?? home ?? "";
  const now = hub.store.now();
  let localSnap = hub.getLocalProjectsCache(wsKey);
  if (localSnap === null) {
    const infoPath = projectsInfoPath(hub.config().agentHome, ws, home);
    const infoSt = await stat(infoPath).catch(() => null);
    const infoMtime = infoSt ? infoSt.mtimeMs : -1;
    const infoSize = infoSt ? infoSt.size : -1;
    const local = hub.store.workspaceProjectNames(ws, home, 200);
    const info = infoSt ? await readProjectsInfoBestEffort(hub.config().agentHome, ws, home) : { projects: {} };
    localSnap = {
      projectNames: local.projects.map((p) => p.name),
      tagNames: local.tags.slice(0, 40).map((t) => t.name),
      infoMtime,
      infoSize,
      infoNames: Object.keys(info.projects),
      infoCheckedAt: now,
    };
    hub.setLocalProjectsCache(wsKey, localSnap);
  } else if (now - localSnap.infoCheckedAt >= INFO_STAT_TTL_MS) {
    const infoPath = projectsInfoPath(hub.config().agentHome, ws, home);
    const infoSt = await stat(infoPath).catch(() => null);
    const infoMtime = infoSt ? infoSt.mtimeMs : -1;
    const infoSize = infoSt ? infoSt.size : -1;
    if (localSnap.infoMtime !== infoMtime || localSnap.infoSize !== infoSize) {
      const info = infoSt ? await readProjectsInfoBestEffort(hub.config().agentHome, ws, home) : { projects: {} };
      localSnap = { ...localSnap, infoMtime, infoSize, infoNames: Object.keys(info.projects), infoCheckedAt: now };
    } else {
      localSnap = { ...localSnap, infoCheckedAt: now };
    }
    hub.setLocalProjectsCache(wsKey, localSnap);
  }
  const cachedPeers = hub.getPeerProjectsCache(wsKey, now, PEER_CACHE_TTL_MS);
  if (cachedPeers === null) {
    // Non-blocking background refresh so next delivery picks up peer projects without stalling this turn.
    hub.triggerPeerProjectsRefresh(wsKey, () => fetchPeerProjectNames(hub, key, ws));
  }
  const peerNames = cachedPeers ?? [];

  const allSet = new Set<string>(localSnap.projectNames);
  for (const name of localSnap.infoNames) allSet.add(name);
  for (const name of peerNames) allSet.add(name);

  const sortedAll = [...allSet].sort();
  const sortedTags = localSnap.tagNames;
  if (sortedAll.length === 0 && sortedTags.length === 0) return null;

  const state = toldMap.get(key) ?? { names: new Set<string>(), tags: new Set<string>() };
  const unseen = sortedAll.filter((n) => !state.names.has(n));
  const unseenTags = sortedTags.filter((t) => !state.tags.has(t));
  const includeTags = unseenTags.length > 0;
  if (unseen.length === 0 && !includeTags) return null;

  const seen = sortedAll.filter((n) => state.names.has(n));
  const ordered = [...unseen, ...seen];

  const emittedNames: string[] = [];
  const emittedTags: string[] = [];
  const render = (pList: string[], tList: string[], more: boolean): string => {
    const lines: string[] = [];
    if (pList.length > 0) {
      lines.push(`Projects: ${pList.map((n) => JSON.stringify(n)).join(", ")}${more ? ", ..." : ""}`);
    }
    if (tList.length > 0) {
      lines.push(`Tags: ${tList.map((t) => JSON.stringify(t)).join(", ")}`);
    }
    return `<workspace-projects>\n${lines.join("\n")}\n</workspace-projects>`;
  };

  const tagReserve = includeTags ? 200 : 0;
  const firstPassLimit = MAX_HEADER_BYTES - tagReserve;
  let nextIdx = 0;
  for (; nextIdx < ordered.length; nextIdx++) {
    const name = ordered[nextIdx]!;
    const candidate = render([...emittedNames, name], emittedTags, nextIdx + 1 < ordered.length);
    if (Buffer.byteLength(candidate, "utf8") > firstPassLimit) break;
    emittedNames.push(name);
  }
  if (includeTags) {
    for (const tag of unseenTags) {
      const candidate = render(emittedNames, [...emittedTags, tag], nextIdx < ordered.length);
      if (Buffer.byteLength(candidate, "utf8") > MAX_HEADER_BYTES) break;
      emittedTags.push(tag);
    }
    // Use any remaining budget below MAX_HEADER_BYTES for additional project names.
    for (; nextIdx < ordered.length; nextIdx++) {
      const name = ordered[nextIdx]!;
      const candidate = render([...emittedNames, name], emittedTags, nextIdx + 1 < ordered.length);
      if (Buffer.byteLength(candidate, "utf8") > MAX_HEADER_BYTES) break;
      emittedNames.push(name);
    }
  }
  if (emittedNames.length === 0 && emittedTags.length === 0) return null;

  const text = render(emittedNames, emittedTags, emittedNames.length < ordered.length);
  return {
    text,
    markTold: () => {
      let cur = toldMap.get(key);
      if (!cur) {
        cur = { names: new Set<string>(), tags: new Set<string>() };
        toldMap.set(key, cur);
      }
      for (const n of emittedNames) cur.names.add(n);
      for (const t of emittedTags) cur.tags.add(t);
    },
  };
}

/// Resolves the target SessionThread for `project_manage(action="propose")`, enforcing membership and `leftAt === null`.
function resolveProposalThread(hub: Hub, key: string, ws: string | null, toRaw: unknown): SessionThread {
  if (typeof toRaw === "string" && toRaw.trim() !== "") {
    const thread = resolveThreadHere(hub, toRaw, ws, key);
    const membership = hub.store.threadSessions(thread.id).find((m) => m.session === key);
    if (!membership) throw new Error(`you are not a member of ${threadAddress(thread.channel, thread.threadTs)}`);
    if (membership.leftAt !== undefined && membership.leftAt !== null) {
      throw new Error(`you left ${threadAddress(thread.channel, thread.threadTs)}: cannot post a proposal there`);
    }
    return { thread, connect: membership.connect };
  }
  const latest = hub.store.latestThread(key);
  if (!latest) throw new Error("no conversation thread found for this session");
  const membership = hub.store.threadSessions(latest.thread.id).find((m) => m.session === key);
  if (membership && membership.leftAt !== undefined && membership.leftAt !== null) {
    throw new Error(`you left ${threadAddress(latest.thread.channel, latest.thread.threadTs)}: cannot post a proposal there`);
  }
  return latest;
}

/// Allowlist of deterministic pre-send / platform-rejection errors where we KNOW the external message was not posted
/// (so clearing the outbox for an immediate retry can never cause duplicate messages). Everything else (timeouts,
/// disconnects, missing platform receipt fields like Feishu `message_id` / Comma `seq`, 5xx) is treated as uncertain.
const DEFINITE_REJECT_ERROR = /channel_not_found|not_in_channel|is_archived|thread_not_found|missing_scope|invalid_auth|not_authed|account_inactive|permission|forbidden|unauthorized|rate_?limited|\b(400|401|403|404|429)\b|msg_too_long/i;

function isDefinitelyNotSent(err: unknown): boolean {
  if (err !== null && typeof err === "object" && (err as { notSent?: unknown }).notSent === true) return true;
  const msg = err instanceof Error ? err.message : String(err);
  return DEFINITE_REJECT_ERROR.test(msg);
}

/// Renders the plain-text body of a project proposal message (used both when posting and when reconciling inbound notice echoes).
/// External messages always embed the stable `proposal.id` marker (`#proposal=<id>` on the link, or `[#<id>]` without link)
/// so echo & history reconciliation never mis-attaches a proposal onto an unrelated or older message.
export function renderProposalText(hub: Hub, thread: ThreadRow, key: string, proposal: ProjectProposal): string {
  const zh = stationLang() === "zh";
  const isExternal = thread.surface !== STILLFAIL_SURFACE;
  const lines: string[] = [];
  if (isExternal) {
    const baseLink = hub.link(thread.home ?? key);
    const withThread = baseLink !== undefined && thread.home === null
      ? `${baseLink}${baseLink.includes("?") ? "&" : "?"}thread=${thread.id}`
      : baseLink;
    const link = withThread !== undefined ? `${withThread}#proposal=${encodeURIComponent(proposal.id)}` : undefined;
    if (zh) {
      lines.push(`建议新建项目「${proposal.name}」并将当前对话归入该项目。`);
      lines.push(link ? `请在 still.fail 中确认：${link}` : `请在 still.fail 中确认该新建项目提案 [#${proposal.id}]。`);
    } else {
      lines.push(`Proposed creating project "${proposal.name}" and assigning this conversation to it.`);
      lines.push(link ? `Confirm in still.fail: ${link}` : `Please confirm this project proposal in still.fail [#${proposal.id}].`);
    }
  } else {
    if (zh) {
      lines.push(`建议新建项目「${proposal.name}」并将当前对话归入该项目。`);
      if (proposal.note !== undefined) lines.push(`说明：${proposal.note}`);
      if (proposal.refs !== undefined && proposal.refs.length > 0) lines.push(`参考：${proposal.refs.join("、")}`);
    } else {
      lines.push(`Proposed creating project "${proposal.name}" and assigning this conversation to it.`);
      if (proposal.note !== undefined) lines.push(`Note: ${proposal.note}`);
      if (proposal.refs !== undefined && proposal.refs.length > 0) lines.push(`Refs: ${proposal.refs.join(", ")}`);
    }
  }
  return lines.join("\n");
}

/// Posts a silent project-creation proposal as a normal message (`entries.proposal`, never `entries.card`).
/// Works uniformly across still.fail chats, Slack, Feishu, group, and Comma (plain text + still.fail link externally).
export async function proposeProject(hub: Hub, key: string, rawArgs: Record<string, unknown>): Promise<string> {
  assertProjectsEnabled(hub);
  const ws = assertCallerWorkspaceAllowed(hub, key);
  const nameRaw = typeof rawArgs.name === "string" ? rawArgs.name : "";
  const name = normalizeProject(nameRaw);
  if (name === "") throw new Error("args.name is required to propose a new project");
  const note = normalizeNote(rawArgs.note);
  const refs = normalizeRefs(rawArgs.refs);
  const target = resolveProposalThread(hub, key, ws, rawArgs.to);
  if (hub.store.manuallyArchived(target.thread.id)) {
    throw new Error(`${threadAddress(target.thread.channel, target.thread.threadTs)} was archived by hand: cannot post proposal`);
  }

  // Deduplicate retries: if this session already has an unresolved pending proposal for the same project in this thread,
  // return it directly without double-posting to external channels.
  const dedupKey = `${target.thread.id}\0${key}\0${name}`;
  const inFlight = hub.inFlightProposals.get(dedupKey);
  if (inFlight !== undefined) return inFlight;

  const run = async (): Promise<string> => {
    const existingPending = hub.store.findPendingProposal(target.thread.id, key, name);
    if (existingPending !== null) {
      hub.store.deletePendingProposalOutbox(target.thread.id, key, name);
      return JSON.stringify({
        proposed: true,
        deduplicated: true,
        id: existingPending.proposal.id,
        name: existingPending.proposal.name,
        thread: target.thread.id,
        n: existingPending.n,
        ts: existingPending.ts,
        reminder: "A project proposal is NOT a blocking question — do not end your turn with need_human for it.",
      });
    }

    const isExternal = target.thread.surface !== STILLFAIL_SURFACE;
    const here = { channel: target.thread.channel, threadTs: target.thread.threadTs };

    // Built-in still.fail chats generate timestamps locally with no external echo: skip `pending_proposals` outbox.
    if (!isExternal) {
      const chat = hub.chat(target.connect);
      const proposal: ProjectProposal = {
        id: `prop-${randomUUID().slice(0, 12)}`,
        name,
        ...(note !== undefined ? { note } : {}),
        ...(refs !== undefined ? { refs } : {}),
        proposer: key,
        status: "pending",
      };
      const text = renderProposalText(hub, target.thread, key, proposal);
      const posted = await chat.post(here, text, []);
      const [n, fresh] = hub.store.insertMessage({
        thread: target.thread.id,
        ts: posted,
        authorKind: "agent",
        author: key,
        text,
        attachments: [],
        proposal,
      });
      if (!fresh) {
        const stored = hub.store.getEntry(target.thread.id, n);
        if (stored?.proposal === undefined) {
          hub.store.attachEntryProposal(target.thread.id, n, proposal);
        }
      }
      const finalEntry = hub.store.getEntry(target.thread.id, n);
      return JSON.stringify({
        proposed: true,
        id: finalEntry?.proposal?.id ?? proposal.id,
        name: proposal.name,
        thread: target.thread.id,
        n,
        ts: finalEntry?.ts ?? posted,
        reminder: "A project proposal is NOT a blocking question — do not end your turn with need_human for it.",
      });
    }

    // Check channel availability BEFORE mutating `pending_proposals` so disconnected channels never poison the outbox.
    const chat = hub.chat(target.connect);

    // Persistent local outbox (`pending_proposals`): preserves stable proposal ID, base_n, sending state, and posted_ts
    // across restarts/retries without double-posting externally, and is cleared as soon as the entry is persisted.
    let outbox = hub.store.getPendingProposalOutbox(target.thread.id, key, name);
    let proposal: ProjectProposal;
    if (outbox !== null) {
      proposal = outbox.payload.proposer ? outbox.payload : { ...outbox.payload, proposer: key };
    } else {
      const baseN = hub.store.lastEntry(target.thread.id);
      proposal = {
        id: `prop-${randomUUID().slice(0, 12)}`,
        name,
        ...(note !== undefined ? { note } : {}),
        ...(refs !== undefined ? { refs } : {}),
        proposer: key,
        status: "pending",
      };
      hub.store.putPendingProposalOutbox(target.thread.id, key, name, proposal, baseN, target.connect);
      outbox = hub.store.getPendingProposalOutbox(target.thread.id, key, name);
      if (outbox !== null) proposal = outbox.payload.proposer ? outbox.payload : { ...outbox.payload, proposer: key };
    }

    const text = renderProposalText(hub, target.thread, key, proposal);

    let posted: string | null = null;
    if (outbox?.postedTs !== null && outbox?.postedTs !== undefined) {
      posted = outbox.postedTs;
    } else if (outbox?.sending === true) {
      // Previous attempt already started external send without saving `posted_ts`: NEVER blindly double-post!
      const fromMem = hub.postedProposalsByOutboxId.get(proposal.id);
      if (fromMem !== undefined) {
        posted = fromMem;
        hub.store.setPendingProposalPostedTs(target.thread.id, key, name, posted);
      } else {
        const echo = hub.store.findEchoEntryAfter(target.thread.id, outbox.baseN, text, proposal.id);
        if (echo !== null) {
          hub.store.attachEntryProposal(target.thread.id, echo.n, proposal);
          const verified = hub.store.getEntry(target.thread.id, echo.n);
          if (verified?.proposal?.id !== proposal.id) {
            throw new Error("failed to verify attached proposal on echoed entry; keeping outbox for retry");
          }
          hub.store.deletePendingProposalOutbox(target.thread.id, key, name);
          hub.postedProposalsByOutboxId.delete(proposal.id);
          return JSON.stringify({
            proposed: true,
            deduplicated: true,
            id: proposal.id,
            name: proposal.name,
            thread: target.thread.id,
            n: echo.n,
            ts: echo.ts,
            reminder: "A project proposal is NOT a blocking question — do not end your turn with need_human for it.",
          });
        }
        // Best-effort resumable thread history fallback when both `chat.post` receipt AND inbound event were lost:
        // prefers native `findNoticeInHistory` (Slack `oldest` + `cursor`), otherwise paginates `chat.history` with
        // persisted `history_cursor` and rejects pre-existing entries (`n <= baseN`).
        if (typeof chat.findNoticeInHistory === "function") {
          try {
            const sinceSec = Math.floor(outbox.createdAt / 1000) - 60;
            const linkMarker = `#proposal=${encodeURIComponent(proposal.id)}`;
            const plainMarker = `[#${proposal.id}]`;
            const primaryMarker = text.includes(linkMarker) ? linkMarker : plainMarker;
            const altMarker = primaryMarker === linkMarker ? plainMarker : linkMarker;
            const maxPages = target.thread.surface.startsWith("group:") ? 40 : 10;
            const isV1Remote = typeof chat.supportsFindNoticeV2 === "function" && !chat.supportsFindNoticeV2();

            let activeMarker = primaryMarker;
            let reqCursor = outbox.historyCursor;
            if (isV1Remote && outbox.historyCursor) {
              try {
                const parsed = JSON.parse(outbox.historyCursor);
                if (parsed !== null && typeof parsed === "object" && typeof parsed.v1m === "string" && parsed.v1m !== "") {
                  activeMarker = parsed.v1m;
                  reqCursor = typeof parsed.c === "string" && parsed.c !== "" ? parsed.c : null;
                }
              } catch {
                // Legacy plain cursor string for primaryMarker.
              }
            }

            let res = await chat.findNoticeInHistory(here, {
              proposalId: proposal.id,
              marker: activeMarker,
              sinceSec,
              cursor: reqCursor,
              maxPages,
            });
            // Mixed-version compatibility: if a remote station only declares V1 `findNoticeInHistory` (without V2),
            // and the primary marker finished scanning with no match, switch to the alternate marker and persist `{ v1m, c }`.
            if (isV1Remote && res && (res.ts === null || res.ts === "") && res.done && activeMarker === primaryMarker) {
              activeMarker = altMarker;
              res = await chat.findNoticeInHistory(here, {
                proposalId: proposal.id,
                marker: activeMarker,
                sinceSec,
                cursor: null,
                maxPages,
              });
            }
            if (res && typeof res.ts === "string" && res.ts !== "") {
              const existingN = hub.store.messageNumberAt(target.thread.id, res.ts);
              const existingEntry = existingN !== null ? hub.store.getEntry(target.thread.id, existingN) : null;
              const valid = existingN === null || (
                existingN > outbox.baseN &&
                (existingEntry?.proposal === undefined || existingEntry.proposal.id === proposal.id)
              );
              if (valid) {
                posted = res.ts;
                hub.postedProposalsByOutboxId.set(proposal.id, posted);
                hub.store.setPendingProposalPostedTs(target.thread.id, key, name, posted);
              }
            } else if (res) {
              if (!res.done && typeof res.cursor === "string" && res.cursor !== "") {
                const nextCursor = isV1Remote ? JSON.stringify({ v1m: activeMarker, c: res.cursor }) : res.cursor;
                hub.store.setPendingProposalHistoryCursor(target.thread.id, key, name, nextCursor);
              } else if (res.done) {
                hub.store.setPendingProposalHistoryCursor(target.thread.id, key, name, null);
              }
            }
          } catch (err) {
            const msg = err instanceof Error ? err.message : String(err);
            if (/invalid_cursor|page_token/i.test(msg)) {
              hub.store.setPendingProposalHistoryCursor(target.thread.id, key, name, null);
            }
          }
        } else if (typeof chat.history === "function") {
          try {
            const botUserId = typeof chat.botUserId === "function" ? chat.botUserId() : "";
            const botId = (typeof chat.botId === "function" ? chat.botId() : "") || chat.identity?.()?.botId || "";
            const isSlack = target.thread.surface.startsWith("slack:");
            const minTsSec = Math.floor(outbox.createdAt / 1000) - 60;
            let before = outbox.historyCursor ?? "";
            let foundTs: string | null = null;
            let reachedEnd = false;
            for (let pageIdx = 0; pageIdx < 10; pageIdx++) {
              const hist = (await chat.history(here, before, 200)) ?? [];
              if (hist.length === 0) {
                reachedEnd = true;
                break;
              }
              const candidates = hist.filter((m) => {
                if (typeof m.text !== "string" || !isNotice(m.text)) return false;
                if (!hasProposalMarker(m.text, proposal.id)) return false;
                const trustedSender =
                  (botUserId !== "" && m.user === botUserId) ||
                  (botId !== "" && m.user === botId);
                if (!trustedSender) return false;
                const existingN = hub.store.messageNumberAt(target.thread.id, m.ts);
                if (existingN !== null) {
                  if (existingN <= outbox!.baseN) return false;
                  const existingEntry = hub.store.getEntry(target.thread.id, existingN);
                  if (existingEntry?.proposal !== undefined && existingEntry.proposal.id !== proposal.id) return false;
                }
                return true;
              });
              if (candidates.length > 0) {
                foundTs = candidates.at(-1)!.ts;
                break;
              }
              const oldestTs = hist[0]!.ts;
              if (!oldestTs || oldestTs === before) {
                reachedEnd = true;
                break;
              }
              if (isSlack) {
                const oldestNum = Number(oldestTs);
                if (Number.isFinite(oldestNum) && oldestNum < minTsSec) {
                  reachedEnd = true;
                  break;
                }
              }
              before = oldestTs;
            }
            if (foundTs !== null) {
              posted = foundTs;
              hub.postedProposalsByOutboxId.set(proposal.id, posted);
              hub.store.setPendingProposalPostedTs(target.thread.id, key, name, posted);
            } else if (reachedEnd) {
              hub.store.setPendingProposalHistoryCursor(target.thread.id, key, name, null);
            } else if (before !== "") {
              hub.store.setPendingProposalHistoryCursor(target.thread.id, key, name, before);
            }
          } catch {
            // Best-effort history reconciliation; fall through to re-check local state before reporting uncertain.
          }
        }
        // Re-check local state after async `chat.history`: an inbound echo may have landed and reconciled while we awaited!
        if (posted === null) {
          const landed = hub.store.findPendingProposal(target.thread.id, key, name);
          if (landed !== null) {
            hub.store.deletePendingProposalOutbox(target.thread.id, key, name);
            hub.postedProposalsByOutboxId.delete(proposal.id);
            return JSON.stringify({
              proposed: true,
              deduplicated: true,
              id: landed.proposal.id,
              name: landed.proposal.name,
              thread: target.thread.id,
              n: landed.n,
              ts: landed.ts,
              reminder: "A project proposal is NOT a blocking question — do not end your turn with need_human for it.",
            });
          }
          const memAfter = hub.postedProposalsByOutboxId.get(proposal.id);
          const outboxAfter = hub.store.getPendingProposalOutbox(target.thread.id, key, name);
          if (memAfter !== undefined) {
            posted = memAfter;
            hub.store.setPendingProposalPostedTs(target.thread.id, key, name, posted);
          } else if (outboxAfter?.postedTs !== null && outboxAfter?.postedTs !== undefined) {
            posted = outboxAfter.postedTs;
          }
        }
        if (posted === null) {
          throw new Error("proposal post receipt is uncertain (external send was already attempted without a saved ts): paused to avoid duplicate messages — wait for the channel echo to reconcile, or ask a member to confirm/create the project directly in still.fail");
        }
      }
    }

    if (posted === null) {
      hub.store.markPendingProposalSending(target.thread.id, key, name);
      try {
        // Post as a plain message (no card, no options, no buttons) with NOTICE_MARK externally so external bots
        // treat it as a silent notice and still.fail clients render the inline proposal bar without pending_cards.
        posted = await chat.post(here, markNotice(text), []);
      } catch (err) {
        if (isDefinitelyNotSent(err)) {
          // Deterministic pre-send or platform rejection (e.g. notSent, channel_not_found, 429): clear outbox so caller can retry.
          hub.store.deletePendingProposalOutbox(target.thread.id, key, name);
        }
        throw err;
      }
      // Record in memory BEFORE persisting to DB so an in-process DB failure on setPendingProposalPostedTs never double-posts.
      hub.postedProposalsByOutboxId.set(proposal.id, posted);
      hub.store.setPendingProposalPostedTs(target.thread.id, key, name, posted);
    }

    // Append-only entries invariant: never UPDATE entries SET proposal.
    // If an external echo already landed on `posted` with proposal=NULL, attach via append-only `entry_proposals`
    // so there is ALWAYS a single local message entry!
    const [n, fresh] = hub.store.insertMessage({
      thread: target.thread.id,
      ts: posted,
      authorKind: "agent",
      author: key,
      text,
      attachments: [],
      proposal,
    });
    if (!fresh) {
      const stored = hub.store.getEntry(target.thread.id, n);
      if (stored?.proposal === undefined) {
        hub.store.attachEntryProposal(target.thread.id, n, proposal);
      }
    }
    const finalEntry = hub.store.getEntry(target.thread.id, n);
    if (finalEntry?.proposal?.id !== proposal.id) {
      throw new Error(`entry at ts ${posted} already carries a different proposal (${finalEntry?.proposal?.id ?? "none"}): keeping outbox intact`);
    }
    hub.store.deletePendingProposalOutbox(target.thread.id, key, name);
    hub.postedProposalsByOutboxId.delete(proposal.id);

    return JSON.stringify({
      proposed: true,
      id: finalEntry.proposal.id,
      name: proposal.name,
      thread: target.thread.id,
      n,
      ts: finalEntry.ts ?? posted,
      reminder: "A project proposal is NOT a blocking question — do not end your turn with need_human for it.",
    });
  };

  const work = run().finally(() => {
    if (hub.inFlightProposals.get(dedupKey) === work) hub.inFlightProposals.delete(dedupKey);
  });
  hub.inFlightProposals.set(dedupKey, work);
  return work;
}

export type RenameMergePeer = {
  station: string;
  name?: string;
  status: "ok" | "offline" | "unsupported" | "rig" | "error";
  updated?: number;
  skippedLocked?: number;
  error?: string;
};

export type RenameMergeResult = {
  action: "rename" | "merge";
  from: string;
  to: string;
  local: { updated: number; skippedLocked: number };
  infoError?: string;
  rosterError?: string;
  peers: RenameMergePeer[];
};

/// Rewrites local carried `preset_projects` entries pointing to `from` -> `to` with `rev++` and notifies SSE.
function rewritePresetProjectsForRename(hub: Hub, ws: string | null, from: string, to: string): void {
  const home = hub.homeWorkspace();
  const now = hub.store.now();
  const wsKeys = new Set<string>([ws ?? home ?? ""]);
  if (ws === null || ws === home) wsKeys.add("");
  for (const wsKey of wsKeys) {
    for (const [sub, rawJson] of hub.store.listPresetProjectsForWorkspace(wsKey)) {
      try {
        const map = presetProjectsOf(JSON.parse(rawJson));
        let changed = false;
        for (const pid of Object.keys(map)) {
          if (Object.hasOwn(map, pid) && map[pid]!.project === from) {
            map[pid] = { project: to, rev: map[pid]!.rev + 1, at: now };
            changed = true;
          }
        }
        if (changed) {
          hub.store.putPresetProjects(wsKey, sub, JSON.stringify(map));
          hub.notifyPresetProjectsChanged(wsKey, sub);
        }
      } catch {
        // Leave unparseable preset_projects row untouched.
      }
    }
  }
}

/// Per-(Hub, workspace) async mutex serializing rename/merge operations so concurrent `X -> Z` and `Y -> Z`
/// can never both pass preflight and silently merge.
const renameLocks = new WeakMap<Hub, Map<string, Promise<void>>>();

async function withWorkspaceRenameLock<T>(hub: Hub, wsKey: string, fn: () => Promise<T>): Promise<T> {
  let byWs = renameLocks.get(hub);
  if (byWs === undefined) {
    byWs = new Map();
    renameLocks.set(hub, byWs);
  }
  const prev = byWs.get(wsKey) ?? Promise.resolve();
  let release!: () => void;
  const next = new Promise<void>((r) => { release = r; });
  const tail = prev.then(() => next, () => next);
  byWs.set(wsKey, tail);
  await prev;
  try {
    return await fn();
  } finally {
    release();
    if (byWs.get(wsKey) === tail) byWs.delete(wsKey);
  }
}

const eventInfoLocks = new WeakMap<Hub, Map<number, Promise<void>>>();

async function withEventInfoLock<T>(hub: Hub, eventSeq: number, fn: () => Promise<T>): Promise<T> {
  let bySeq = eventInfoLocks.get(hub);
  if (bySeq === undefined) {
    bySeq = new Map();
    eventInfoLocks.set(hub, bySeq);
  }
  const prev = bySeq.get(eventSeq) ?? Promise.resolve();
  let release!: () => void;
  const next = new Promise<void>((r) => { release = r; });
  const tail = prev.then(() => next, () => next);
  bySeq.set(eventSeq, tail);
  await prev;
  try {
    return await fn();
  } finally {
    release();
    if (bySeq.get(eventSeq) === tail) bySeq.delete(eventSeq);
  }
}

/// Renames or merges project `fromRaw` -> `toRaw` locally and across all reachable workspace peers, updating `PROJECTS.jsonl`
/// and any carried `preset_projects` defaults pointing to `from`.
/// Shared by `project_manage(action="rename"|"merge")` and member HTTP routes `POST /projects/rename|merge`.
export async function renameOrMergeProject(
  hub: Hub,
  ws: string | null,
  action: "rename" | "merge",
  fromRaw: string,
  toRaw: string,
  opts?: { key?: string | null; checkKnown?: boolean; skipPrivate?: boolean; opKey?: string },
): Promise<RenameMergeResult> {
  assertProjectsEnabled(hub);
  let from: string;
  let to: string;
  try {
    from = normalizeProject(fromRaw);
    to = normalizeProject(toRaw);
  } catch (e) {
    throw new HttpRefused(400, (e as Error).message);
  }
  if (from === "") throw new HttpRefused(400, "from is required");
  if (to === "" && action === "rename") throw new HttpRefused(400, "to is required for rename");
  if (from === to) throw new HttpRefused(400, "from and to must differ");
  const key = opts?.key ?? null;
  const skipPrivate = opts?.skipPrivate ?? false;
  const opKey = typeof opts?.opKey === "string" && opts.opKey.trim() !== "" ? opts.opKey.trim() : null;
  const home = hub.homeWorkspace();
  const wsKey = ws ?? home ?? "";

  // Phase 1 (under workspace mutex): preflight + atomic local commit only, then release lock BEFORE peer RPC fan-out
  // so two peers concurrently renaming disjoint projects never AB-BA deadlock on `classifyForPeer`.
  const call = key !== null ? peersOf(hub, key) : hub.peersInWorkspace(ws);
  const phase1 = await withWorkspaceRenameLock(hub, wsKey, async () => {
    const existingByOp = opKey !== null ? hub.store.findProjectRenameByOpKey(wsKey, opKey) : null;
    if (existingByOp !== null) {
      if (existingByOp.action !== action || existingByOp.from !== from || existingByOp.to !== to) {
        throw new HttpRefused(409, "idempotency key already used for a different project rename/merge");
      }
      if (existingByOp.pendingPeers.length === 0 && !existingByOp.pendingRoster && existingByOp.pendingInfoState === 0) {
        return {
          done: true as const,
          result: {
            action,
            from: existingByOp.from,
            to: existingByOp.to,
            local: { updated: 0, skippedLocked: 0 },
            peers: [],
          },
        };
      }
    }
    const unfinished = existingByOp ?? hub.store.findUnfinishedProjectRename(wsKey, action, from, to);
    const isContinuation = unfinished !== null;

    if (!isContinuation && hub.store.hasUnfinishedRenameFrom(wsKey, from, to)) {
      throw new HttpRefused(
        409,
        `previous rename/merge from ${JSON.stringify(from)} still has pending work; retry it to completion before renaming ${JSON.stringify(from)} again`,
        { noCache: true },
      );
    }

    if (!isContinuation && opts?.checkKnown !== false) {
      await assertKnownProject(hub, key, ws, from, { fresh: true, skipPrivate, strictPeer: false });
      if (action === "merge" && to !== "") {
        await assertKnownProject(hub, key, ws, to, { fresh: true, skipPrivate, strictPeer: false });
      }
      if (action === "rename") {
        if (hub.store.hasPendingProjectTarget(wsKey, to)) {
          throw new HttpRefused(409, `project ${JSON.stringify(to)} is already targeted by an unfinished rename/merge`, { noCache: true });
        }
        if (await isKnownProject(hub, key, ws, to, { fresh: true, skipPrivate, strictPeer: true, offlineIsUncertain: true })) {
          throw new HttpRefused(409, `project ${JSON.stringify(to)} already exists; use merge instead`);
        }
      }
    }

    let roster: Json = null;
    let rosterError: string | undefined;
    if (call) {
      try {
        roster = await call("", { method: "peers" });
      } catch (e) {
        rosterError = (e as Error).message;
      }
    }
    const selfId = hub.station() ?? "";
    const stations: { id: string; name?: string; online?: boolean }[] = Array.isArray(roster?.stations) ? roster.stations : [];
    const allOtherStations = stations.filter((s) => typeof s?.id === "string" && s.id !== "" && s.id !== selfId);

    if (isContinuation) {
      if (opKey !== null && existingByOp === null) {
        hub.store.bindProjectRenameOpKey(wsKey, opKey, unfinished.seq);
      }
      return {
        done: false as const,
        isContinuation: true,
        eventSeq: unfinished.seq,
        originSeq: unfinished.originSeq,
        opId: unfinished.opId ?? randomUUID(),
        renamedAt: unfinished.renamedAt,
        wallAt: unfinished.wallAt,
        local: { updated: 0, skippedLocked: 0 },
        pendingPeers: unfinished.pendingPeers,
        pendingRoster: unfinished.pendingRoster,
        pendingInfoState: unfinished.pendingInfoState,
        phase1InfoError: undefined as string | undefined,
        rosterError,
        allOtherStations,
      };
    }

    const opId = randomUUID();
    // Strictly monotonic logical timestamp per workspace prevents same-ms collisions across chained renames and peers,
    // while `wallAt` preserves the real wall-clock time so explicit user rev+1 edits after same-ms renames inherit the watermark.
    const wallAt = hub.store.now();
    const lastRenamedAt = hub.store.maxProjectRenameAt(wsKey);
    const renamedAt = Math.max(wallAt, lastRenamedAt + 1);
    const pendingRoster = Boolean(call && rosterError !== undefined);
    let pendingInfoState: 0 | 1 | 2 | 3 = 1;
    const initialPending = pendingRoster ? [] : allOtherStations.map((t) => t.id);
    const committed = hub.store.commitLocalProjectRenameAtomic({
      ws,
      home,
      action,
      from,
      to,
      renamedAt,
      wallAt,
      opKey,
      opId,
      pendingPeers: initialPending,
      pendingRoster,
      pendingInfo: true,
    });
    for (const [wk, sub] of committed.presetNotifies) hub.notifyPresetProjectsChanged(wk, sub);

    // Execute local PROJECTS.jsonl migration BEFORE releasing the workspace lock and fanning out peer RPCs
    // (pure local disk I/O, zero RPCs -> zero deadlock risk), so a newly created same-name project during
    // in-flight peer RPCs can never be clobbered by this rename's initial info migration.
    let phase1InfoError: string | undefined;
    await withEventInfoLock(hub, committed.seq, async () => {
      try {
        const keepOpIds = hub.store.listPendingRenameInfoOpIds(wsKey);
        const infoRes = await renameProjectInfo(hub.config().agentHome, ws, home, from, to, renamedAt, {
          createIfMissing: committed.local.updated > 0,
          opId,
          keepOpIds,
        });
        if (infoRes.changed) hub.notifyProjectsChanged(ws);
        const nextState: 0 | 2 =
          infoRes.alreadyApplied === true || infoRes.changed || committed.local.updated > 0 || (initialPending.length === 0 && !pendingRoster) ? 0 : 2;
        hub.store.markRenameInfoState(committed.seq, nextState);
        pendingInfoState = nextState;
        await pruneAppliedOpIds(hub.config().agentHome, ws, home, [opId], hub.store.listPendingRenameInfoOpIds(wsKey)).catch(() => {});
      } catch (e) {
        phase1InfoError = (e as Error).message;
      }
    });

    return {
      done: false as const,
      isContinuation: false,
      eventSeq: committed.seq,
      originSeq: committed.originSeq,
      opId,
      renamedAt,
      wallAt,
      local: committed.local,
      pendingPeers: initialPending,
      pendingRoster,
      pendingInfoState,
      phase1InfoError,
      rosterError,
      allOtherStations,
    };
  });

  if (phase1.done) return phase1.result;

  // Phase 2 (outside workspace mutex): monotonic peer fan-out & 4-state `pending_info` (`0|1|2|3`) convergence.
  let { rosterError } = phase1;
  const { pendingRoster, isContinuation, eventSeq, originSeq, opId, renamedAt, wallAt, local, allOtherStations } = phase1;
  const peers: RenameMergePeer[] = [];
  const resolvedPeers: string[] = [];

  if (!call) {
    if (isContinuation && (phase1.pendingPeers.length > 0 || pendingRoster)) {
      rosterError = "peer transport unavailable";
    }
  } else if (rosterError === undefined) {
    let targets: { id: string; name?: string; online?: boolean }[];
    if (pendingRoster) {
      const claimed = hub.store.claimRenameRosterResult(eventSeq, allOtherStations.map((s) => s.id));
      if (claimed) {
        targets = allOtherStations;
      } else {
        const latest = hub.store.getProjectRenameEvent(eventSeq);
        const byId = new Map(allOtherStations.map((s) => [s.id, s]));
        targets = (latest?.pendingPeers ?? []).map((id) => byId.get(id) ?? { id, online: false });
      }
    } else {
      const pendingSet = new Set(phase1.pendingPeers);
      const byId = new Map(allOtherStations.map((s) => [s.id, s]));
      targets = [...pendingSet].map((id) => byId.get(id) ?? { id, online: false });
    }
    await Promise.all(targets.map(async (p) => {
      if (p.online === false) {
        peers.push({ station: p.id, ...(p.name ? { name: p.name } : {}), status: "offline" });
        if (action === "merge") resolvedPeers.push(p.id);
        return;
      }
      try {
        const res = await call(p.id, { method: THREAD_CLASSIFY, rename: { from, to, action, opId, renamedAt, wallAt, originSeq } });
        peers.push({
          station: p.id,
          ...(p.name ? { name: p.name } : {}),
          status: "ok",
          updated: Number(res?.updated ?? 0),
          skippedLocked: Number(res?.skippedLocked ?? 0),
        });
        resolvedPeers.push(p.id);
      } catch (e) {
        const msg = (e as Error).message;
        if (isRigRefusal(msg)) {
          peers.push({ station: p.id, ...(p.name ? { name: p.name } : {}), status: "rig" });
          resolvedPeers.push(p.id);
        } else if (e instanceof Refused && isUnsupportedError(msg)) {
          peers.push({ station: p.id, ...(p.name ? { name: p.name } : {}), status: "unsupported" });
          resolvedPeers.push(p.id);
        } else if (/timed out|offline|not connected|unreachable|PeerGone/i.test(msg)) {
          peers.push({ station: p.id, ...(p.name ? { name: p.name } : {}), status: "offline", error: msg });
          if (action === "merge") resolvedPeers.push(p.id);
        } else {
          peers.push({ station: p.id, ...(p.name ? { name: p.name } : {}), status: "error", error: msg });
        }
      }
    }));
    const anyRemoteUpdated = peers.some((p) => (p.updated ?? 0) > 0);
    hub.store.markRenamePeersResolved(eventSeq, resolvedPeers, anyRemoteUpdated);
  }

  const totalUpdated = local.updated + peers.reduce((acc, p) => acc + (p.updated ?? 0), 0);
  let infoError: string | undefined = phase1.phase1InfoError;
  await withEventInfoLock(hub, eventSeq, async () => {
    const latest = hub.store.getProjectRenameEvent(eventSeq);
    if (latest === null) return;
    if (latest.pendingInfoState === 1 && isContinuation) {
      try {
        const effectiveInfoTo = forwardResolveTarget(hub.store.listProjectRenameEvents(wsKey), to, renamedAt, originSeq, opId, wallAt).target;
        const hadAnyUpdated = totalUpdated > 0 || latest.localUpdated > 0 || latest.remoteUpdated;
        const keepOpIds = hub.store.listPendingRenameInfoOpIds(wsKey);
        const infoRes = await renameProjectInfo(hub.config().agentHome, ws, home, from, effectiveInfoTo, renamedAt, {
          createIfMissing: hadAnyUpdated,
          opId,
          keepOpIds,
        });
        if (infoRes.changed) hub.notifyProjectsChanged(ws);
        const nextState: 0 | 2 =
          infoRes.alreadyApplied === true ||
          infoRes.changed ||
          hadAnyUpdated ||
          (latest.pendingPeers.length === 0 && !latest.pendingRoster)
            ? 0
            : 2;
        hub.store.markRenameInfoState(eventSeq, nextState);
        await pruneAppliedOpIds(hub.config().agentHome, ws, home, [opId], hub.store.listPendingRenameInfoOpIds(wsKey)).catch(() => {});
      } catch (e) {
        infoError = (e as Error).message;
      }
    } else if (latest.pendingInfoState === 3) {
      const effectiveInfoTo = forwardResolveTarget(hub.store.listProjectRenameEvents(wsKey), to, renamedAt, originSeq, opId, wallAt).target;
      try {
        if (effectiveInfoTo !== "") {
          const reg = await ensureProjectRegistered(hub.config().agentHome, ws, home, {
            name: effectiveInfoTo,
            now: renamedAt,
            keepOpIds: hub.store.listPendingRenameInfoOpIds(wsKey),
          });
          if (reg.changed) hub.notifyProjectsChanged(ws);
        }
        hub.store.markRenameInfoState(eventSeq, 0);
      } catch (e) {
        infoError = (e as Error).message;
      }
    } else if (latest.pendingInfoState === 2 && latest.pendingPeers.length === 0 && !latest.pendingRoster) {
      hub.store.markRenameInfoState(eventSeq, 0);
    }
  });
  hub.invalidateProjectsCache(ws);
  return {
    action,
    from,
    to,
    local,
    ...(infoError !== undefined ? { infoError } : {}),
    ...(rosterError !== undefined ? { rosterError } : {}),
    peers,
  };
}

/// Main dispatcher for the `project_manage` MCP tool.
export async function projectManage(hub: Hub, key: string, raw: Args): Promise<string> {
  assertProjectsEnabled(hub);
  const ws = assertCallerWorkspaceAllowed(hub, key);
  const action = typeof raw.action === "string" ? raw.action.trim() : "";
  const args = raw.args !== null && typeof raw.args === "object" && !Array.isArray(raw.args)
    ? (raw.args as Record<string, unknown>)
    : {};
  const home = hub.homeWorkspace();

  switch (action) {
    case "list": {
      const data = await collectWorkspaceProjects(hub, key);
      return JSON.stringify(data, null, 2);
    }
    case "propose":
      return proposeProject(hub, key, args);
    case "set_info": {
      if (typeof args.name !== "string") throw new Error("args.name is required");
      const name = normalizeProject(args.name);
      if (name === "") throw new Error("args.name must be a non-empty project name");
      if (args.note !== undefined && args.note !== null && typeof args.note !== "string") {
        throw new Error("args.note must be a string or null");
      }
      if (args.refs !== undefined && args.refs !== null && (!Array.isArray(args.refs) || args.refs.some((x) => typeof x !== "string"))) {
        throw new Error("args.refs must be an array of strings or null");
      }
      if (args.delete !== true) {
        await assertKnownProject(hub, key, ws, name);
      }
      const { doc } = await updateProjectInfo(hub.config().agentHome, ws, home, {
        name,
        ...(args.note !== undefined ? { note: args.note as string | null } : {}),
        ...(args.refs !== undefined ? { refs: args.refs as string[] | null } : {}),
        ...(args.delete === true ? { delete: true } : {}),
        now: hub.store.now(),
        keepOpIds: hub.store.listPendingRenameInfoOpIds(ws ?? home ?? ""),
      });
      hub.notifyProjectsChanged(ws);
      return JSON.stringify({ updated: true, project: name, info: stripInternalProjectInfo(doc).projects[name] ?? null });
    }
    case "rename":
    case "merge": {
      if (typeof args.from !== "string") throw new Error("args.from must be a string");
      if (typeof args.to !== "string") throw new Error("args.to must be a string");
      const res = await renameOrMergeProject(hub, ws, action, args.from, args.to, { key, checkKnown: true });
      return JSON.stringify(res, null, 2);
    }
    case "reclassify": {
      const items = Array.isArray(args.items) ? args.items : [];
      if (items.length === 0) throw new Error("args.items must be a non-empty array of { chat, project?, tags?, tags_add?, tags_remove? }");
      if (items.length > 100) throw new Error("args.items supports at most 100 chats per call");
      const results: Record<string, unknown>[] = [];
      for (const item of items) {
        if (item === null || typeof item !== "object" || Array.isArray(item)) {
          results.push({ ok: false, error: "item must be an object" });
          continue;
        }
        const rec = item as Record<string, unknown>;
        const chat = typeof rec.chat === "string" ? rec.chat : "";
        try {
          const input = parseClassificationArgs(rec);
          const rawRes = await classifyChat(hub, key, chat, input);
          results.push({ chat, ok: true, result: JSON.parse(rawRes) });
        } catch (e) {
          results.push({ chat, ok: false, error: (e as Error).message });
        }
      }
      return JSON.stringify({ results }, null, 2);
    }
    default:
      throw new Error(
        action === "create"
          ? 'creating a project directly is not allowed: use action "propose" to post a confirmation bar for a member'
          : `unknown action ${JSON.stringify(action)}: expected list, propose, set_info, rename, merge, or reclassify`,
      );
  }
}
