// T3 Code session importer: discovers threads in ~/.t3/userdata/statev2.sqlite (and legacy v1 state.sqlite),
// reads user/assistant messages, and copies native Antigravity (agy) / Claude / Codex runtime state for live resume.
import { copyFile, cp, mkdir, readdir, realpath, rename, rm, stat, writeFile } from "node:fs/promises";
import { dirname, join, relative } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { agyBaseModel, agyHome, geminiDir } from "../agents/agy.ts";
import type { RuntimeKind } from "../agents/runtime.ts";
import { log } from "../ops/log.ts";
import { walkBounded } from "../ops/walk.ts";
import { extension, ROLLOUT_DEPTH, ROLLOUT_ENTRIES, rolloutOf, roots as defaultMachineRoots, transcriptOf } from "../read/machine.ts";
import { sharedTranscripts } from "../read/transcript.ts";
import type { ImportCandidate, ImportMessage, ImportOptions, ImportSource, ImportSourceSummary, ImportThreadDetail, PrepareNativeInput } from "./types.ts";

const SAFE_ID = /^[A-Za-z0-9_-]+$/;
const MAX_THREADS = 2000;
const MAX_MESSAGES = 5000;

let copySeq = 0;

/// Default T3 Code userdata directory: `options.t3DataDir`, `$T3_DATA_DIR`, `$T3CODE_HOME`, or `$HOME/.t3/userdata`.
export function t3UserdataDir(options?: ImportOptions): string {
  if (options?.t3DataDir) return options.t3DataDir;
  if (process.env.T3_DATA_DIR) return process.env.T3_DATA_DIR;
  if (process.env.T3CODE_HOME) return process.env.T3CODE_HOME;
  const home = process.env.HOME ?? process.env.USERPROFILE ?? ".";
  return join(home, ".t3", "userdata");
}

async function isFile(path: string): Promise<boolean> {
  try {
    return (await stat(path)).isFile();
  } catch {
    return false;
  }
}

async function isDir(path: string): Promise<boolean> {
  try {
    return (await stat(path)).isDirectory();
  } catch {
    return false;
  }
}

async function exists(path: string): Promise<boolean> {
  try {
    await stat(path);
    return true;
  } catch {
    return false;
  }
}

async function findT3Db(userdata: string): Promise<string | null> {
  for (const name of ["statev2.sqlite", "state.sqlite"]) {
    const candidate = join(userdata, name);
    if (await isFile(candidate)) return candidate;
  }
  return null;
}

/// Maps a T3 Code provider/driver name to a still.fail RuntimeKind, or null when unsupported natively.
export function mapT3Provider(provider: string | null | undefined): RuntimeKind | null {
  const raw = (provider ?? "").trim().toLowerCase();
  if (raw === "antigravity" || raw === "agy") return "agy";
  if (raw === "claude" || raw === "claudeagent" || raw === "claude-code" || raw === "claude_code") return "claude";
  if (raw === "codex" || raw === "openai-codex") return "codex";
  if (raw === "grok" || raw === "grok-build") return "grok";
  if (raw === "cursor") return "cursor";
  if (raw === "devin") return "devin";
  if (raw === "hermes") return "hermes";
  if (raw === "dsh" || raw === "deepseek-harness") return "dsh";
  if (raw === "pi") return "pi";
  return null;
}

function parseIsoMs(raw: unknown): number {
  if (typeof raw === "number" && Number.isFinite(raw)) return raw;
  if (typeof raw !== "string" || raw === "") return 0;
  const parsed = Date.parse(raw);
  return Number.isFinite(parsed) ? parsed : 0;
}

function parseJson(raw: unknown): Record<string, unknown> | null {
  if (typeof raw !== "string" || raw === "") return null;
  try {
    const parsed = JSON.parse(raw);
    return parsed !== null && typeof parsed === "object" && !Array.isArray(parsed) ? (parsed as Record<string, unknown>) : null;
  } catch {
    return null;
  }
}

function isInternalThreadId(id: string): boolean {
  return id.startsWith("thread:subagent:") || id.startsWith("thread:delegated-task:");
}

function extractModelAndEffort(
  threadPayload: Record<string, unknown> | null,
  sessionPayload: Record<string, unknown> | null,
  sessionModel: string | null,
): { model: string | null; effort: string | null } {
  const selection =
    threadPayload?.modelSelection && typeof threadPayload.modelSelection === "object" && !Array.isArray(threadPayload.modelSelection)
      ? (threadPayload.modelSelection as Record<string, unknown>)
      : null;
  const rawModel =
    (typeof selection?.model === "string" && selection.model.trim() !== "" ? selection.model.trim() : null) ??
    (typeof sessionPayload?.model === "string" && sessionPayload.model.trim() !== "" ? sessionPayload.model.trim() : null) ??
    (typeof sessionModel === "string" && sessionModel.trim() !== "" ? sessionModel.trim() : null);

  let effort: string | null = null;
  if (Array.isArray(selection?.options)) {
    for (const opt of selection.options) {
      if (!opt || typeof opt !== "object") continue;
      const o = opt as Record<string, unknown>;
      if ((o.id === "thought_level" || o.id === "reasoning_effort" || o.id === "effort") && typeof o.value === "string" && o.value.trim() !== "") {
        effort = o.value.trim();
        break;
      }
    }
  }
  if (rawModel !== null) {
    const split = agyBaseModel(rawModel);
    return { model: split.model || rawModel, effort: effort ?? split.effort ?? null };
  }
  return { model: null, effort };
}

function extractNativeId(providerThreadPayload: Record<string, unknown> | null): string | null {
  if (!providerThreadPayload) return null;
  const ref = providerThreadPayload.nativeThreadRef;
  if (ref && typeof ref === "object" && !Array.isArray(ref)) {
    const nativeId = (ref as Record<string, unknown>).nativeId;
    if (typeof nativeId === "string" && SAFE_ID.test(nativeId)) return nativeId;
  }
  const direct = providerThreadPayload.nativeThreadId;
  if (typeof direct === "string" && SAFE_ID.test(direct)) return direct;
  return null;
}

/// Lists all candidate Antigravity CLI/ACP storage roots under `<t3Userdata>/providers/antigravity/*/`.
async function t3AgyRoots(userdata: string): Promise<string[]> {
  const base = join(userdata, "providers", "antigravity");
  let entries: string[];
  try {
    entries = (await readdir(base)).sort();
  } catch {
    return [];
  }
  const roots: string[] = [];
  for (const name of entries) {
    for (const appDir of ["antigravity-acp", "antigravity-cli"]) {
      const dir = join(base, name, appDir);
      if (await isDir(join(dir, "conversations"))) roots.push(dir);
    }
  }
  return roots;
}

/// Finds the Antigravity storage root under T3 Code that contains `conversations/<nativeId>.db`.
async function findT3AgyRoot(roots: readonly string[], nativeId: string | null): Promise<string | null> {
  if (nativeId === null || !SAFE_ID.test(nativeId)) return null;
  for (const dir of roots) {
    if (await isFile(join(dir, "conversations", `${nativeId}.db`))) return dir;
  }
  return null;
}

function tableExists(db: DatabaseSync, name: string): boolean {
  return db.prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?").get(name) !== undefined;
}

function hasV2Threads(db: DatabaseSync): boolean {
  if (!tableExists(db, "orchestration_v2_projection_threads")) return false;
  const row = db.prepare("SELECT count(*) AS n FROM orchestration_v2_projection_threads").get() as { n: number } | undefined;
  return (row?.n ?? 0) > 0;
}

type RawThreadRow = {
  id: string;
  title: string;
  project: string | null;
  projectCwd: string | null;
  provider: string | null;
  cwd: string | null;
  model: string | null;
  effort: string | null;
  messageCount: number;
  createdAt: number;
  updatedAt: number;
  archived: boolean;
  nativeId: string | null;
};

function queryThreadsV2(db: DatabaseSync, includeArchived: boolean, onlyId?: string): RawThreadRow[] {
  const hasProjects = tableExists(db, "projection_projects");
  const hasMessages = tableExists(db, "orchestration_v2_projection_messages");
  const hasSessions = tableExists(db, "orchestration_v2_projection_provider_sessions");
  const hasProviderThreads = tableExists(db, "orchestration_v2_projection_provider_threads");

  const where: string[] = ["t.deleted_at IS NULL"];
  const params: string[] = [];
  if (!includeArchived && onlyId === undefined) where.push("t.archived_at IS NULL");
  if (onlyId !== undefined) {
    where.push("t.thread_id = ?");
    params.push(onlyId);
  }

  const sql = `
    SELECT
      t.thread_id AS id,
      t.title AS title,
      t.default_provider AS default_provider,
      t.created_at AS created_at,
      t.updated_at AS updated_at,
      t.archived_at AS archived_at,
      t.payload_json AS thread_payload,
      ${hasProjects ? "p.title" : "NULL"} AS project_title,
      ${hasProjects ? "p.workspace_root" : "NULL"} AS project_cwd,
      ${hasMessages ? "(SELECT count(*) FROM orchestration_v2_projection_messages m WHERE m.thread_id = t.thread_id AND m.role IN ('user', 'assistant'))" : "0"} AS msg_count,
      ${hasSessions ? "(SELECT ps.provider FROM orchestration_v2_projection_provider_sessions ps WHERE ps.thread_id = t.thread_id ORDER BY ps.updated_at DESC LIMIT 1)" : "NULL"} AS ps_provider,
      ${hasSessions ? "(SELECT ps.model FROM orchestration_v2_projection_provider_sessions ps WHERE ps.thread_id = t.thread_id ORDER BY ps.updated_at DESC LIMIT 1)" : "NULL"} AS ps_model,
      ${hasSessions ? "(SELECT ps.payload_json FROM orchestration_v2_projection_provider_sessions ps WHERE ps.thread_id = t.thread_id ORDER BY ps.updated_at DESC LIMIT 1)" : "NULL"} AS ps_payload,
      ${hasProviderThreads ? "(SELECT pt.driver FROM orchestration_v2_projection_provider_threads pt WHERE pt.thread_id = t.thread_id ORDER BY pt.updated_at DESC LIMIT 1)" : "NULL"} AS pt_driver,
      ${hasProviderThreads ? "(SELECT pt.payload_json FROM orchestration_v2_projection_provider_threads pt WHERE pt.thread_id = t.thread_id ORDER BY pt.updated_at DESC LIMIT 1)" : "NULL"} AS pt_payload
    FROM orchestration_v2_projection_threads t
    ${hasProjects ? "LEFT JOIN projection_projects p ON p.project_id = t.project_id" : ""}
    WHERE ${where.join(" AND ")}
    ORDER BY t.updated_at DESC
    LIMIT ${MAX_THREADS}
  `;
  const rows = db.prepare(sql).all(...params) as Record<string, unknown>[];
  const out: RawThreadRow[] = [];
  for (const r of rows) {
    const id = typeof r.id === "string" ? r.id : "";
    if (id === "" || (onlyId === undefined && isInternalThreadId(id))) continue;
    const threadPayload = parseJson(r.thread_payload);
    const sessionPayload = parseJson(r.ps_payload);
    const ptPayload = parseJson(r.pt_payload);
    const provider =
      (typeof r.pt_driver === "string" && r.pt_driver !== "" ? r.pt_driver : null) ??
      (typeof r.ps_provider === "string" && r.ps_provider !== "" ? r.ps_provider : null) ??
      (typeof r.default_provider === "string" && r.default_provider !== "" ? r.default_provider : null);
    const { model, effort } = extractModelAndEffort(threadPayload, sessionPayload, typeof r.ps_model === "string" ? r.ps_model : null);
    const cwd =
      (typeof sessionPayload?.cwd === "string" && sessionPayload.cwd.trim() !== "" ? sessionPayload.cwd.trim() : null) ??
      (typeof threadPayload?.worktreePath === "string" && threadPayload.worktreePath.trim() !== "" ? threadPayload.worktreePath.trim() : null) ??
      (typeof r.project_cwd === "string" && r.project_cwd.trim() !== "" ? r.project_cwd.trim() : null);
    const project = typeof r.project_title === "string" && r.project_title.trim() !== "" && r.project_title !== "No project" ? r.project_title.trim() : null;
    const title = typeof r.title === "string" && r.title.trim() !== "" ? r.title.trim() : id;
    out.push({
      id,
      title,
      project,
      projectCwd: typeof r.project_cwd === "string" ? r.project_cwd : null,
      provider,
      cwd,
      model,
      effort,
      messageCount: typeof r.msg_count === "number" ? r.msg_count : 0,
      createdAt: parseIsoMs(r.created_at),
      updatedAt: parseIsoMs(r.updated_at),
      archived: r.archived_at !== null && r.archived_at !== undefined && r.archived_at !== "",
      nativeId: extractNativeId(ptPayload),
    });
  }
  return out;
}

function queryThreadsV1(db: DatabaseSync, includeArchived: boolean, onlyId?: string): RawThreadRow[] {
  if (!tableExists(db, "projection_threads")) return [];
  const hasProjects = tableExists(db, "projection_projects");
  const hasMessages = tableExists(db, "projection_thread_messages");
  const hasSessions = tableExists(db, "projection_thread_sessions");

  const where: string[] = ["t.deleted_at IS NULL"];
  const params: string[] = [];
  if (!includeArchived && onlyId === undefined) where.push("t.archived_at IS NULL");
  if (onlyId !== undefined) {
    where.push("t.thread_id = ?");
    params.push(onlyId);
  }

  const sql = `
    SELECT
      t.thread_id AS id,
      t.title AS title,
      t.worktree_path AS worktree_path,
      t.model_selection_json AS model_selection_json,
      t.created_at AS created_at,
      t.updated_at AS updated_at,
      t.archived_at AS archived_at,
      ${hasProjects ? "p.title" : "NULL"} AS project_title,
      ${hasProjects ? "p.workspace_root" : "NULL"} AS project_cwd,
      ${hasMessages ? "(SELECT count(*) FROM projection_thread_messages m WHERE m.thread_id = t.thread_id AND m.role IN ('user', 'assistant'))" : "0"} AS msg_count,
      ${hasSessions ? "s.provider_name" : "NULL"} AS provider_name,
      ${hasSessions ? "s.provider_thread_id" : "NULL"} AS provider_thread_id,
      ${hasSessions ? "s.provider_session_id" : "NULL"} AS provider_session_id
    FROM projection_threads t
    ${hasProjects ? "LEFT JOIN projection_projects p ON p.project_id = t.project_id" : ""}
    ${hasSessions ? "LEFT JOIN projection_thread_sessions s ON s.thread_id = t.thread_id" : ""}
    WHERE ${where.join(" AND ")}
    ORDER BY t.updated_at DESC
    LIMIT ${MAX_THREADS}
  `;
  const rows = db.prepare(sql).all(...params) as Record<string, unknown>[];
  const out: RawThreadRow[] = [];
  for (const r of rows) {
    const id = typeof r.id === "string" ? r.id : "";
    if (id === "" || (onlyId === undefined && isInternalThreadId(id))) continue;
    const sel = parseJson(r.model_selection_json);
    const provider =
      (typeof r.provider_name === "string" && r.provider_name !== "" ? r.provider_name : null) ??
      (typeof sel?.provider === "string" && sel.provider !== "" ? sel.provider : null);
    const rawModel = typeof sel?.model === "string" && sel.model.trim() !== "" ? sel.model.trim() : null;
    const split = rawModel !== null ? agyBaseModel(rawModel) : null;
    const cwd =
      (typeof r.worktree_path === "string" && r.worktree_path.trim() !== "" ? r.worktree_path.trim() : null) ??
      (typeof r.project_cwd === "string" && r.project_cwd.trim() !== "" ? r.project_cwd.trim() : null);
    const project = typeof r.project_title === "string" && r.project_title.trim() !== "" && r.project_title !== "No project" ? r.project_title.trim() : null;
    const title = typeof r.title === "string" && r.title.trim() !== "" ? r.title.trim() : id;
    const rawNative =
      (typeof r.provider_thread_id === "string" && SAFE_ID.test(r.provider_thread_id) ? r.provider_thread_id : null) ??
      (typeof r.provider_session_id === "string" && SAFE_ID.test(r.provider_session_id) ? r.provider_session_id : null);
    out.push({
      id,
      title,
      project,
      projectCwd: typeof r.project_cwd === "string" ? r.project_cwd : null,
      provider,
      cwd,
      model: split?.model ?? rawModel,
      effort: split?.effort ?? null,
      messageCount: typeof r.msg_count === "number" ? r.msg_count : 0,
      createdAt: parseIsoMs(r.created_at),
      updatedAt: parseIsoMs(r.updated_at),
      archived: r.archived_at !== null && r.archived_at !== undefined && r.archived_at !== "",
      nativeId: rawNative,
    });
  }
  return out;
}

function queryMessagesV2(db: DatabaseSync, threadId: string): ImportMessage[] {
  if (!tableExists(db, "orchestration_v2_projection_messages")) return [];
  const rows = db
    .prepare(
      `SELECT role, created_at, payload_json, search_text
       FROM orchestration_v2_projection_messages
       WHERE thread_id = ? AND role IN ('user', 'assistant')
       ORDER BY created_at ASC, rowid ASC
       LIMIT ${MAX_MESSAGES}`,
    )
    .all(threadId) as { role: string; created_at: string; payload_json: string | null; search_text: string | null }[];
  const out: ImportMessage[] = [];
  for (const r of rows) {
    const payload = parseJson(r.payload_json);
    const text =
      (typeof payload?.text === "string" ? payload.text : null) ??
      (typeof r.search_text === "string" ? r.search_text : "");
    if (text.trim() === "") continue;
    out.push({
      role: r.role === "user" ? "user" : "assistant",
      text,
      at: parseIsoMs(payload?.createdAt ?? r.created_at),
    });
  }
  return out;
}

function queryMessagesV1(db: DatabaseSync, threadId: string): ImportMessage[] {
  if (!tableExists(db, "projection_thread_messages")) return [];
  const rows = db
    .prepare(
      `SELECT role, text, created_at
       FROM projection_thread_messages
       WHERE thread_id = ? AND role IN ('user', 'assistant')
       ORDER BY created_at ASC, rowid ASC
       LIMIT ${MAX_MESSAGES}`,
    )
    .all(threadId) as { role: string; text: string | null; created_at: string }[];
  const out: ImportMessage[] = [];
  for (const r of rows) {
    const text = typeof r.text === "string" ? r.text : "";
    if (text.trim() === "") continue;
    out.push({
      role: r.role === "user" ? "user" : "assistant",
      text,
      at: parseIsoMs(r.created_at),
    });
  }
  return out;
}

async function resolveNativePath(
  runtime: RuntimeKind | null,
  nativeId: string | null,
  agyRoots: readonly string[],
  options?: ImportOptions,
): Promise<string | null> {
  if (runtime === null || nativeId === null || !SAFE_ID.test(nativeId)) return null;
  if (runtime === "agy") return findT3AgyRoot(agyRoots, nativeId);
  if (runtime === "claude" || runtime === "codex") {
    const mRoots = options?.machineRoots ?? defaultMachineRoots();
    return transcriptOf(mRoots, runtime, nativeId);
  }
  return null;
}

/// Copies an Antigravity conversation from T3 Code's `antigravity-acp` store into a still.fail profile's `antigravity-cli`
/// store atomically (matching `agyBringIn`), and writes the station's KeptTranscript JSONL so both `AgyDriver.starting()`
/// and execution history reads succeed immediately.
async function prepareAgyNative(input: PrepareNativeInput): Promise<boolean> {
  const { detail, profileHome, dataDir, cwd } = input;
  const id = detail.nativeId;
  const fromCli = detail.nativePath;
  if (id === null || !SAFE_ID.test(id) || fromCli === null) return false;
  const srcDb = join(fromCli, "conversations", `${id}.db`);
  if (!(await isFile(srcDb))) return false;

  const toCli = join(geminiDir(profileHome), "antigravity-cli");
  const toConvDir = join(toCli, "conversations");
  await mkdir(toConvDir, { recursive: true });
  const dstDb = join(toConvDir, `${id}.db`);
  const srcWal = join(fromCli, "conversations", `${id}.db-wal`);
  const hasWal = await isFile(srcWal);

  const n = ++copySeq;
  const dbStaging = `${dstDb}.${process.pid}.${n}.importing`;
  const walStaging = `${dstDb}-wal.${process.pid}.${n}.importing`;
  await cp(srcDb, dbStaging, { preserveTimestamps: true });
  if (hasWal) await cp(srcWal, walStaging, { preserveTimestamps: true });

  for (const [sub, entry] of [["annotations", `${id}.pbtxt`], ["brain", id]] as const) {
    const src = join(fromCli, sub, entry);
    if (!(await exists(src))) continue;
    await mkdir(join(toCli, sub), { recursive: true });
    await rm(join(toCli, sub, entry), { recursive: true, force: true });
    await cp(src, join(toCli, sub, entry), { recursive: true, preserveTimestamps: true });
  }

  await rm(`${dstDb}-wal`, { force: true });
  await rm(`${dstDb}-shm`, { force: true });
  await rename(dbStaging, dstDb);
  if (hasWal) await rename(walStaging, `${dstDb}-wal`);

  // Write KeptTranscript JSONL so AgyDriver.starting() accepts `resume` and execution history renders prior turns.
  const lines: string[] = [
    JSON.stringify({ time: detail.createdAt || detail.updatedAt, type: "session", id, cwd }),
  ];
  for (const m of detail.messages) {
    lines.push(JSON.stringify({ time: m.at || detail.updatedAt, type: m.role, text: m.text }));
  }
  lines.push(JSON.stringify({ time: detail.updatedAt || detail.createdAt, type: "end", status: "finished" }));
  const content = `${lines.join("\n")}\n`;

  const profileSessions = join(agyHome(profileHome), "sessions");
  const shared = sharedTranscripts(dataDir, "agy");
  await mkdir(profileSessions, { recursive: true });
  await writeFile(join(profileSessions, `${id}.jsonl`), content, "utf8");
  const realProfile = await realpath(profileSessions).catch(() => profileSessions);
  const realShared = await realpath(shared).catch(() => null);
  if (realShared !== realProfile) {
    await mkdir(shared, { recursive: true });
    await writeFile(join(shared, `${id}.jsonl`), content, "utf8");
  }
  log.info("imports::t3", "prepared native Antigravity conversation for imported T3 thread", { thread: detail.id, nativeId: id });
  return true;
}

/// Copies a Claude Code or Codex transcript into still.fail's shared transcript directory without modifying the original.
async function prepareMachineTranscript(input: PrepareNativeInput): Promise<boolean> {
  const { detail, runtime, dataDir, options } = input;
  if ((runtime !== "claude" && runtime !== "codex") || detail.nativeId === null || detail.nativePath === null) return false;
  const mRoots = options?.machineRoots ?? defaultMachineRoots();
  const root = runtime === "claude" ? mRoots.claude : mRoots.codex;
  const files = [detail.nativePath];
  if (runtime === "codex") {
    await walkBounded(
      root,
      (e) => {
        if (e.file && e.depth > 0 && e.name.startsWith("rollout-") && extension(e.name) === "jsonl" && e.path !== detail.nativePath && rolloutOf(e.path, detail.nativeId!)) {
          files.push(e.path);
        }
      },
      { maxDepth: ROLLOUT_DEPTH, maxEntries: ROLLOUT_ENTRIES, followRoot: true },
    );
  }
  const shared = sharedTranscripts(dataDir, runtime);
  for (const from of files) {
    const rel = relative(root, from);
    if (rel === "" || rel.startsWith("..")) return false;
    const to = join(shared, rel);
    await mkdir(dirname(to), { recursive: true });
    const partial = `${to.replace(/\.jsonl$/, "")}.jsonl.part`;
    await copyFile(from, partial);
    await rename(partial, to);
  }
  return true;
}

export const t3ImportSource: ImportSource = {
  id: "t3",
  name: "T3 Code",

  async probe(options?: ImportOptions): Promise<Omit<ImportSourceSummary, "importedCount">> {
    const userdata = t3UserdataDir(options);
    const dbPath = await findT3Db(userdata);
    if (dbPath === null) {
      return { id: "t3", name: "T3 Code", available: false, dataPath: null, activeCount: 0, archivedCount: 0, error: null };
    }
    let db: DatabaseSync | null = null;
    try {
      db = new DatabaseSync(dbPath, { readOnly: true, timeout: 2000 });
      const rows = hasV2Threads(db) ? queryThreadsV2(db, true) : queryThreadsV1(db, true);
      let activeCount = 0;
      let archivedCount = 0;
      for (const r of rows) {
        if (r.archived) archivedCount++;
        else activeCount++;
      }
      return { id: "t3", name: "T3 Code", available: true, dataPath: dbPath, activeCount, archivedCount, error: null };
    } catch (e) {
      return { id: "t3", name: "T3 Code", available: false, dataPath: dbPath, activeCount: 0, archivedCount: 0, error: (e as Error).message };
    } finally {
      db?.close();
    }
  },

  async list(opts?: { includeArchived?: boolean }, options?: ImportOptions): Promise<ImportCandidate[]> {
    const userdata = t3UserdataDir(options);
    const dbPath = await findT3Db(userdata);
    if (dbPath === null) return [];
    const agyRoots = await t3AgyRoots(userdata);
    let rows: RawThreadRow[];
    let db: DatabaseSync | null = null;
    try {
      db = new DatabaseSync(dbPath, { readOnly: true, timeout: 2000 });
      rows = hasV2Threads(db) ? queryThreadsV2(db, opts?.includeArchived === true) : queryThreadsV1(db, opts?.includeArchived === true);
    } finally {
      db?.close();
    }
    const out: ImportCandidate[] = [];
    for (const r of rows) {
      const runtime = mapT3Provider(r.provider);
      const nativePath = await resolveNativePath(runtime, r.nativeId, agyRoots, options);
      out.push({
        source: "t3",
        id: r.id,
        title: r.title,
        project: r.project,
        cwd: r.cwd,
        provider: r.provider,
        runtime,
        model: r.model,
        effort: r.effort,
        messageCount: r.messageCount,
        updatedAt: r.updatedAt,
        createdAt: r.createdAt,
        archived: r.archived,
        nativeResumable: nativePath !== null,
        session: null,
      });
    }
    return out;
  },

  async read(id: string, options?: ImportOptions): Promise<ImportThreadDetail | null> {
    const userdata = t3UserdataDir(options);
    const dbPath = await findT3Db(userdata);
    if (dbPath === null) return null;
    const agyRoots = await t3AgyRoots(userdata);
    let row: RawThreadRow | undefined;
    let messages: ImportMessage[] = [];
    let db: DatabaseSync | null = null;
    try {
      db = new DatabaseSync(dbPath, { readOnly: true, timeout: 2000 });
      const v2 = hasV2Threads(db);
      row = (v2 ? queryThreadsV2(db, true, id) : queryThreadsV1(db, true, id))[0];
      if (row !== undefined) messages = v2 ? queryMessagesV2(db, id) : queryMessagesV1(db, id);
    } finally {
      db?.close();
    }
    if (row === undefined) return null;
    const runtime = mapT3Provider(row.provider);
    const nativePath = await resolveNativePath(runtime, row.nativeId, agyRoots, options);
    return {
      source: "t3",
      id: row.id,
      title: row.title,
      project: row.project,
      cwd: row.cwd,
      provider: row.provider,
      runtime,
      model: row.model,
      effort: row.effort,
      messageCount: messages.length || row.messageCount,
      updatedAt: row.updatedAt,
      createdAt: row.createdAt,
      archived: row.archived,
      nativeResumable: nativePath !== null,
      session: null,
      nativeId: row.nativeId,
      nativePath,
      messages,
    };
  },

  async prepareNative(input: PrepareNativeInput): Promise<boolean> {
    if (input.runtime === "agy") return prepareAgyNative(input);
    if (input.runtime === "claude" || input.runtime === "codex") return prepareMachineTranscript(input);
    return false;
  },
};
