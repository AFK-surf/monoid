// Session import orchestrator: source registry, deduplication, chat creation, history replay, and native runtime handoff.
import { mkdir } from "node:fs/promises";
import { join } from "node:path";
import type { Profile, RuntimeKind } from "../agents/runtime.ts";
import { type Lang, stationLang, tr } from "../ops/i18n.ts";
import { log } from "../ops/log.ts";
import { type Hub, newChatKey, newToken } from "../sessions/hub.ts";
import { chatWorkspace, INTERNAL_CONNECT } from "../sessions/internal.ts";
import { openChat } from "../sessions/lifecycle.ts";
import { STATION_AUTHOR } from "../store/rows.ts";
import { t3ImportSource } from "./t3.ts";
import type {
  ImportCandidate,
  ImportItemOutcome,
  ImportOptions,
  ImportRunRequest,
  ImportRunResult,
  ImportSource,
  ImportSourceSummary,
  ImportThreadDetail,
} from "./types.ts";

/// Registered external import sources. Add new importers here as they are implemented.
export const IMPORT_SOURCES: readonly ImportSource[] = [t3ImportSource];

export function findImportSource(id: string): ImportSource | null {
  return IMPORT_SOURCES.find((s) => s.id === id) ?? null;
}

/// Lists all registered import sources with availability, session counts, and already-imported counts for `ws`.
export async function listImportSources(hub: Hub, ws: string | null = null, options?: ImportOptions): Promise<ImportSourceSummary[]> {
  const out: ImportSourceSummary[] = [];
  for (const source of IMPORT_SOURCES) {
    const probed = await source.probe(options);
    const imported = hub.store.importedSessionsOf(source.id, ws);
    out.push({ ...probed, importedCount: imported.size });
  }
  return out;
}

/// Lists importable sessions for `sourceId`, annotated with any existing still.fail session key in `ws`.
export async function listImportCandidates(
  hub: Hub,
  sourceId: string,
  ws: string | null = null,
  opts?: { includeArchived?: boolean },
  options?: ImportOptions,
): Promise<ImportCandidate[]> {
  const source = findImportSource(sourceId);
  if (source === null) throw new Error(`unknown import source: ${sourceId}`);
  const candidates = await source.list(opts, options);
  const imported = hub.store.importedSessionsOf(source.id, ws);
  return candidates.map((c) => ({
    ...c,
    session: imported.get(c.id) ?? null,
  }));
}

const FALLBACK_RUNTIMES: readonly RuntimeKind[] = ["agy", "claude", "codex", "grok", "dsh", "cursor", "devin", "hermes", "pi"];

/// Picks the best profile and runtime for an imported thread in `ws`.
function chooseProfile(
  hub: Hub,
  ws: string | null,
  preferredRuntime: RuntimeKind | null,
  preferredModel: string | null,
): { runtime: RuntimeKind; profile: Profile; model: string | null; matchedRuntime: boolean } | null {
  const all = hub.profilesIn(ws);
  if (all.length === 0) return null;
  if (preferredRuntime !== null) {
    const matching = all.filter((p) => p.runtimes.includes(preferredRuntime));
    if (matching.length > 0) {
      const keptModel = preferredModel !== null && matching.some((p) => p.models.includes(preferredModel)) ? preferredModel : null;
      const profile = hub.accounts.pick(matching, keptModel, false);
      const model = keptModel ?? profile.model ?? profile.models[0] ?? null;
      return { runtime: preferredRuntime, profile, model, matchedRuntime: true };
    }
  }
  for (const rt of FALLBACK_RUNTIMES) {
    const matching = all.filter((p) => p.runtimes.includes(rt));
    if (matching.length === 0) continue;
    const profile = hub.accounts.pick(matching, null, false);
    const model = profile.model ?? profile.models[0] ?? null;
    return { runtime: rt, profile, model, matchedRuntime: false };
  }
  const first = all[0]!;
  const rt = first.runtimes[0];
  if (!rt) return null;
  return { runtime: rt, profile: first, model: first.model ?? first.models[0] ?? null, matchedRuntime: false };
}

async function resolveCwd(hub: Hub, candidate: string | null, lang: Lang): Promise<string | null> {
  if (candidate === null || candidate.trim() === "") return null;
  try {
    await hub.places.directory(candidate, { lang });
    return candidate;
  } catch {
    return null;
  }
}

async function importOne(
  hub: Hub,
  source: ImportSource,
  detail: ImportThreadDetail,
  createdBy: string,
  lang: Lang,
  ws: string | null,
  options?: ImportOptions,
): Promise<ImportItemOutcome> {
  const existingKey = hub.store.importedSession(source.id, detail.id, ws);
  if (existingKey !== null) {
    const existingThread = hub.store.homeChat(existingKey);
    if (existingThread !== null) {
      return { id: detail.id, title: detail.title, status: "skipped", session: existingKey, thread: existingThread.id };
    }
  }

  const picked = chooseProfile(hub, ws, detail.runtime, detail.model);
  if (picked === null) {
    return { id: detail.id, title: detail.title, status: "failed", error: tr(lang, "station.import.noProfile") };
  }

  const config = hub.config();
  const key = newChatKey();
  const workspace = chatWorkspace(config.dataDir, key);
  await mkdir(workspace, { recursive: true });
  await mkdir(join(config.dataDir, "repos"), { recursive: true });

  const validCwd = await resolveCwd(hub, detail.cwd, lang);
  const runCwd = validCwd ?? workspace;

  let resumed = false;
  if (picked.matchedRuntime && detail.nativeId !== null && detail.nativePath !== null && source.prepareNative !== undefined) {
    try {
      resumed = await source.prepareNative({
        detail,
        runtime: picked.runtime,
        profileHome: picked.profile.home,
        dataDir: config.dataDir,
        cwd: runCwd,
        options,
      });
    } catch (e) {
      log.warn("imports", "native runtime transfer failed; importing chat history only", {
        source: source.id,
        id: detail.id,
        runtime: picked.runtime,
        error: (e as Error).message,
      });
      resumed = false;
    }
  }

  const now = hub.now();
  const title = Array.from(detail.title).slice(0, 80).join("") || null;
  const createdAt = detail.createdAt > 0 ? detail.createdAt : now;
  const lastActiveAt = detail.updatedAt > 0 ? detail.updatedAt : now;

  hub.store.insertSession({
    key,
    connect: INTERNAL_CONNECT,
    scope: "all",
    title,
    createdBy,
    runtime: picked.runtime,
    profile: picked.profile.id,
    profilePinned: false,
    model: picked.model,
    effort: picked.matchedRuntime ? detail.effort : null,
    fast: null,
    workspace,
    cwd: validCwd,
    runtimeSessionId: resumed ? detail.nativeId : null,
    token: newToken(),
    createdAt,
    lastActiveAt,
    ...(ws !== null ? { ws } : {}),
  });

  const thread = openChat(hub, key, createdBy, title);
  const noteKey = resumed
    ? (validCwd !== null ? "station.import.noteResumedCwd" : "station.import.noteResumed")
    : (validCwd !== null ? "station.import.noteHistoryCwd" : "station.import.noteHistory");
  const note = tr(lang, noteKey, {
    source: source.name,
    ...(validCwd !== null ? { cwd: validCwd } : {}),
    n: String(detail.messages.length),
  });
  hub.store.insertMessage({
    thread: thread.id,
    ts: hub.nextTs(),
    authorKind: STATION_AUTHOR,
    author: STATION_AUTHOR,
    text: note,
    at: createdAt,
  });

  for (const m of detail.messages) {
    const at = m.at > 0 ? m.at : lastActiveAt;
    hub.store.insertMessage({
      thread: thread.id,
      ts: hub.nextTs(),
      authorKind: m.role === "user" ? "person" : "agent",
      author: m.role === "user" ? createdBy : key,
      text: m.text,
      at,
      ...(m.role === "assistant" ? { runtime: picked.runtime, profile: picked.profile.id } : {}),
    });
  }

  // Mark all imported history as read for the importer so batch imports do not flood unread indicators.
  hub.store.setRead(createdBy, thread.id, hub.store.lastEntry(thread.id));
  hub.store.recordImportedSession(source.id, detail.id, key, ws);

  log.info("imports", "imported external conversation", {
    source: source.id,
    externalId: detail.id,
    session: key,
    thread: thread.id,
    runtime: picked.runtime,
    resumed,
    messages: detail.messages.length,
  });

  return { id: detail.id, title: detail.title, status: "imported", session: key, thread: thread.id, resumed };
}

/// Runs a one-click or targeted import from `sourceId` into `hub` for workspace `ws`.
export async function runImport(
  hub: Hub,
  sourceId: string,
  request: ImportRunRequest,
  createdBy: string,
  lang: Lang = stationLang(),
  ws: string | null = null,
  options?: ImportOptions,
): Promise<ImportRunResult> {
  const source = findImportSource(sourceId);
  if (source === null) throw new Error(tr(lang, "station.import.unknownSource", { source: sourceId }));

  let targetIds: string[];
  if (Array.isArray(request.ids) && request.ids.length > 0) {
    targetIds = [...new Set(request.ids.filter((id): id is string => typeof id === "string" && id.trim() !== ""))];
  } else {
    const listed = await source.list({ includeArchived: request.includeArchived === true }, options);
    targetIds = listed.map((c) => c.id);
  }

  const items: ImportItemOutcome[] = [];
  let imported = 0;
  let skipped = 0;
  let failed = 0;

  for (const id of targetIds) {
    const existingKey = hub.store.importedSession(source.id, id, ws);
    if (existingKey !== null) {
      const existingThread = hub.store.homeChat(existingKey);
      if (existingThread !== null) {
        const existingSession = hub.store.getSession(existingKey);
        items.push({ id, title: existingSession?.title ?? id, status: "skipped", session: existingKey, thread: existingThread.id });
        skipped++;
        continue;
      }
    }
    const detail = await source.read(id, options);
    if (detail === null) {
      items.push({ id, title: id, status: "failed", error: tr(lang, "station.import.notFound", { id }) });
      failed++;
      continue;
    }
    const outcome = await importOne(hub, source, detail, createdBy, lang, ws, options);
    items.push(outcome);
    if (outcome.status === "imported") imported++;
    else if (outcome.status === "skipped") skipped++;
    else failed++;
  }

  return { source: source.id, imported, skipped, failed, items };
}
