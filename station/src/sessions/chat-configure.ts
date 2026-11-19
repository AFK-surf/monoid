// An agent reads or changes a session's runtime configuration (runtime, model, effort, speed, context, preset, repick),
// here or on another station of its workspace. Uses the same lifecycle as the app's POST /sessions/:key (`configure`).
import { modelSpeed } from "../../../client/core-ts/src/model-speed.ts";
import { RUNTIME_KINDS, type RuntimeKind } from "../agents/runtime.ts";
import { Refused } from "../jobs/remote.ts";
import type { SessionRow } from "../store/rows.ts";
import type { SessionChange } from "./accounts.ts";
import { type Args, jsString } from "./args.ts";
import { runs } from "./config.ts";
import { contextAsked } from "./context-cap.ts";
import type { Hub } from "./hub.ts";
import { configure } from "./lifecycle.ts";
import { elsewhere, fromBefore, linkedSession, named, peersOf, scopeOf, threadIn } from "./others.ts";

type Json = any;

export const CONFIGURE = "session.configure";

const CHANGE_KEYS = ["runtime", "model", "effort", "speed", "fast", "context", "preset", "repick"] as const;

function trimmed(v: unknown): string | null {
  if (v === undefined || v === null) return null;
  const s = jsString(v).trim();
  return s === "" ? null : s;
}

function describeRow(hub: Hub, row: SessionRow) {
  return {
    session: row.key,
    link: hub.link(row.key) ?? null,
    runtime: row.runtime,
    model: row.model,
    effort: row.effort,
    speed: row.speed ?? null,
    fast: row.fast,
    context: row.context,
    profile: row.profile,
    running: row.running,
    archived: row.archivedAt !== null,
    created_by: row.createdBy,
  };
}

function resolveHere(hub: Hub, chat: string, ws: string | null, caller: string | null): string {
  if (chat === "" || chat.toLowerCase() === "self") {
    if (caller === null) throw new Error("chat is required");
    return caller;
  }
  const reference = chat.includes("/o/") || chat.includes("/chats/") ? chat.split("?")[0]! : chat;
  const what = named(hub, reference, ws);
  if (what.type === "session") {
    if (ws !== null && !hub.inWorkspace(what.key, ws)) {
      throw new Error("that chat is in another workspace: only this workspace's chats can be configured");
    }
    return what.key;
  }
  if (!threadIn(hub, what.thread, ws)) {
    throw new Error("that chat is in another workspace: only this workspace's chats can be configured");
  }
  if (what.thread.home !== null) return what.thread.home;
  const agents = hub.store.threadSessions(what.thread.id).map((m) => m.session);
  if (agents.length === 0) throw new Error(`${reference} has no agent session to configure`);
  if (agents.length > 1) throw new Error(`${reference} has several agents; pass one session key as chat: ${agents.join(", ")}`);
  return agents[0]!;
}

async function parseChange(hub: Hub, ws: string | null, args: Args): Promise<SessionChange | null> {
  if (!CHANGE_KEYS.some((k) => args[k] !== undefined)) return null;
  const presetName = trimmed(args.preset);
  if (presetName !== null) {
    for (const k of ["runtime", "model", "effort", "speed", "fast", "context"] as const) {
      if (args[k] !== undefined) {
        throw new Error("preset cannot be combined with runtime, model, effort, speed, fast or context");
      }
    }
    const all = await hub.presets.list(ws ?? hub.workspaces()[0] ?? null);
    const lower = presetName.toLowerCase();
    const preset = all.find((p) => p.id === presetName) ?? all.find((p) => p.name.toLowerCase() === lower);
    if (!preset) {
      if (all.length === 0) throw new Error(`no preset ${presetName}: this station has none`);
      throw new Error(`no preset ${presetName} on this station; its presets: ${all.map((p) => p.name).join(", ")}`);
    }
    if (!preset.model) throw new Error(`the preset ${preset.name} does not configure a model`);
    const pm = preset.model;
    const change: SessionChange = {
      ...(pm.runtime ? { runtime: pm.runtime } : {}),
      model: pm.model,
      effort: pm.effort ?? null,
      fast: pm.fast ?? null,
      speed: pm.speed ?? null,
      context: pm.context ?? null,
      ...(pm.profiles !== undefined ? { profiles: pm.profiles } : pm.profile !== undefined ? { profile: pm.profile } : { profile: null }),
    };
    if (args.repick !== undefined) {
      if (typeof args.repick !== "boolean") throw new Error("repick must be true or false");
      if (args.repick) change.repick = true;
    }
    return change;
  }
  const change: SessionChange = {};
  if (args.runtime !== undefined) {
    const runtime = trimmed(args.runtime);
    if (runtime === null || !RUNTIME_KINDS.includes(runtime as RuntimeKind)) {
      throw new Error(`runtime must be one of ${RUNTIME_KINDS.join(", ")}`);
    }
    change.runtime = runtime;
  }
  if (args.model !== undefined) {
    change.model = args.model === null ? null : trimmed(args.model);
  }
  if (args.effort !== undefined) {
    change.effort = args.effort === null ? null : trimmed(args.effort);
  }
  if (args.speed !== undefined) {
    if (args.speed === null || trimmed(args.speed) === null) change.speed = null;
    else {
      const speed = modelSpeed(args.speed);
      if (speed === null) throw new Error("speed must be standard, fast or ultrafast");
      change.speed = speed;
    }
  }
  if (args.fast !== undefined) {
    if (args.fast !== null && typeof args.fast !== "boolean") throw new Error("fast must be true, false or null");
    change.fast = args.fast;
  }
  if (args.context !== undefined) {
    change.context = args.context === null || args.context === 0 ? null : (contextAsked(args.context, "en") ?? null);
  }
  if (args.repick !== undefined) {
    if (typeof args.repick !== "boolean") throw new Error("repick must be true or false");
    if (args.repick) change.repick = true;
  }
  return change;
}

function parsePeerChange(raw: Json): SessionChange | null {
  if (raw === undefined || raw === null) return null;
  if (typeof raw !== "object" || Array.isArray(raw)) throw new Error("change must be an object");
  const change: SessionChange = {};
  if ("runtime" in raw) {
    if (typeof raw.runtime !== "string" || !RUNTIME_KINDS.includes(raw.runtime as RuntimeKind)) {
      throw new Error(`runtime must be one of ${RUNTIME_KINDS.join(", ")}`);
    }
    change.runtime = raw.runtime;
  }
  if ("model" in raw) change.model = raw.model === null ? null : trimmed(raw.model);
  if ("effort" in raw) change.effort = raw.effort === null ? null : trimmed(raw.effort);
  if ("speed" in raw) {
    if (raw.speed === null || trimmed(raw.speed) === null) change.speed = null;
    else {
      const speed = modelSpeed(raw.speed);
      if (speed === null) throw new Error("speed must be standard, fast or ultrafast");
      change.speed = speed;
    }
  }
  if ("fast" in raw) {
    if (raw.fast !== null && typeof raw.fast !== "boolean") throw new Error("fast must be true, false or null");
    change.fast = raw.fast;
  }
  if ("context" in raw) {
    change.context = raw.context === null || raw.context === 0 ? null : (contextAsked(raw.context, "en") ?? null);
  }
  if ("profile" in raw) {
    if (raw.profile !== null && typeof raw.profile !== "string") throw new Error("profile must be a string or null");
    change.profile = raw.profile;
  }
  if ("profiles" in raw) {
    if (raw.profiles !== null && (!Array.isArray(raw.profiles) || raw.profiles.some((x: unknown) => typeof x !== "string"))) {
      throw new Error("profiles must be a list of profile ids or null");
    }
    change.profiles = raw.profiles;
  }
  if (raw.repick === true) change.repick = true;
  return Object.keys(change).length === 0 ? null : change;
}

async function applyHere(hub: Hub, targetKey: string, change: SessionChange | null): Promise<string> {
  const row = hub.store.getSession(targetKey);
  if (!row) throw new Error(`unknown session ${targetKey}`);
  if (change === null) return JSON.stringify(describeRow(hub, row), null, 2);
  let next = change;
  if (next.runtime === undefined && typeof next.model === "string" && next.model !== "") {
    const available = hub.profilesIn(row.ws ?? null);
    const fitsCurrent = available.some((p) => p.runtimes.includes(row.runtime as RuntimeKind) && runs(p, next.model!));
    if (!fitsCurrent) {
      const matching = [...new Set(available.filter((p) => runs(p, next.model!)).flatMap((p) => p.runtimes))];
      if (matching.length === 1) next = { ...next, runtime: matching[0]! };
      else if (matching.length > 1) throw new Error(`model ${next.model} runs on multiple runtimes (${matching.join(", ")}): pass runtime`);
    }
  }
  const before = describeRow(hub, row);
  await configure(hub, targetKey, next, "en");
  const after = describeRow(hub, hub.store.getSession(targetKey) ?? row);
  return JSON.stringify({ updated: true, before, after }, null, 2);
}

export async function chatConfigure(hub: Hub, key: string, args: Args): Promise<string> {
  const ws = scopeOf(hub, key);
  const chat = typeof args.chat === "string" ? args.chat.trim() : "";
  const change = await parseChange(hub, ws, args);
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
    const targetKey = resolveHere(hub, targetChat, ws, key);
    return applyHere(hub, targetKey, change);
  }
  const call = peersOf(hub, key);
  if (!call) throw new Error("other stations cannot be reached from this one yet");
  let answer: Json;
  try {
    answer = await call(station, { method: CONFIGURE, session: key, chat: targetChat, ...(change !== null ? { change } : {}) });
  } catch (error) {
    const why = (error as Error).message;
    if (error instanceof Refused && fromBefore(why)) {
      throw new Error(`station ${station} is not updated yet: its chats cannot be configured from here`);
    }
    throw new Error(`configure request to station ${station} failed: ${why}`);
  }
  if (typeof answer?.text !== "string") throw new Error(`station ${station} answered without a configure result`);
  return answer.text;
}

/// A station of the workspace asks to read or configure one of its chats here; cross-workspace shares do not grant this.
export async function configureForPeer(hub: Hub, request: Json, ws: string | null = null): Promise<{ text: string }> {
  const chat = typeof request?.chat === "string" ? request.chat.trim() : "";
  if (chat === "") throw new Error("chat is required");
  const targetKey = resolveHere(hub, chat, ws, null);
  const change = parsePeerChange(request?.change);
  return { text: await applyHere(hub, targetKey, change) };
}
