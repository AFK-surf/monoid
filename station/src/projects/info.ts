// Shared workspace project metadata (`PROJECTS.jsonl`) synced across stations via `share/memory.ts`
// (same sync path as `MEMORY.md` and workspace skills).
// Each line is one compact JSON object `{ name, note?, refs?, updatedAt? }`, sorted by `name` UTF-8 bytes,
// ending with `\n`. This makes 3-way and 2-way line-level merges deterministic and valid JSONL.
import { chmod, mkdir, readFile, rename, stat, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { workspaceAgentHomePath } from "../sessions/agent-home.ts";
import { log } from "../ops/log.ts";
import { byBytes, normalizeProject } from "../store/rows.ts";

export const PROJECTS_INFO_FILE = "PROJECTS.jsonl";
export const MAX_PROJECT_NOTE = 2000;
export const MAX_PROJECT_REFS = 32;
export const MAX_PROJECT_REF_LEN = 512;
/// Shared 512 KiB size ceiling (same constant as `share/memory.ts` `FILE_MOST`).
export const PROJECTS_INFO_MAX_BYTES = 512 * 1024;
const FILE_MOST = PROJECTS_INFO_MAX_BYTES;

/// Whether a file mode is owner-only private (`0600` / `0700`: no group/other bits).
export const isOwnPrivateMode = (mode: number): boolean => (mode & 0o077) === 0;

export type ProjectInfoEntry = {
  note?: string;
  noteAt?: number;
  refs?: string[];
  refsAt?: number;
  refAts?: Record<string, number>;
  updatedAt?: number;
  noteClearedAt?: number;
  refsClearedAt?: number;
};

function maxEntryTimestamp(e: ProjectInfoEntry | undefined): number {
  if (!e) return -Infinity;
  let m = Math.max(
    e.updatedAt ?? -Infinity,
    e.noteAt ?? -Infinity,
    e.refsAt ?? -Infinity,
    e.noteClearedAt ?? -Infinity,
    e.refsClearedAt ?? -Infinity,
  );
  if (e.refAts) {
    for (const v of Object.values(e.refAts)) {
      if (typeof v === "number" && Number.isFinite(v) && v > m) m = v;
    }
  }
  return m;
}

function emptyRefAtsMap(): Record<string, number> {
  return Object.create(null) as Record<string, number>;
}

function sortRefsByAt(refAts: Record<string, number>): string[] {
  return Object.keys(refAts).sort((a, b) => {
    const da = refAts[a]!;
    const db = refAts[b]!;
    if (da !== db) return db - da;
    return a < b ? -1 : a > b ? 1 : 0;
  });
}

export type ProjectsInfoDoc = {
  projects: Record<string, ProjectInfoEntry>;
};

export type ReadProjectsOpts = {
  /// When true (e.g. peer RPCs), treat `0600` private files as absent so private projects never leak to peers.
  skipPrivate?: boolean;
};

/// Creates a null-prototype map so project names like `__proto__` or `constructor` are always safe keys.
export function emptyProjectsMap(): Record<string, ProjectInfoEntry> {
  return Object.create(null) as Record<string, ProjectInfoEntry>;
}

/// Per-file in-process mutex chain shared between local API writes and `MemorySync.#write`.
const pathLocks = new Map<string, Promise<void>>();
export async function withProjectsFileLock<T>(path: string, fn: () => Promise<T>): Promise<T> {
  const prev = pathLocks.get(path) ?? Promise.resolve();
  let release!: () => void;
  const mine = new Promise<void>((resolve) => { release = resolve; });
  const tail = prev.then(() => mine, () => mine);
  pathLocks.set(path, tail);
  await prev;
  try {
    return await fn();
  } finally {
    release();
    if (pathLocks.get(path) === tail) pathLocks.delete(path);
  }
}

export function normalizeNote(raw: unknown, strict = false): string | undefined {
  if (raw === undefined || raw === null) return undefined;
  if (typeof raw !== "string") {
    if (strict) throw new Error("note must be a string or null");
    return undefined;
  }
  const s = raw.trim();
  if (s === "") return undefined;
  if (s.length > MAX_PROJECT_NOTE) {
    if (strict) throw new Error(`note must be at most ${MAX_PROJECT_NOTE} characters`);
    return s.slice(0, MAX_PROJECT_NOTE);
  }
  return s;
}

export function normalizeRefs(raw: unknown, strict = false): string[] | undefined {
  if (raw === undefined || raw === null) return undefined;
  if (!Array.isArray(raw)) {
    if (strict) throw new Error("refs must be an array of strings or null");
    return undefined;
  }
  const out: string[] = [];
  const seen = new Set<string>();
  for (const item of raw) {
    if (typeof item !== "string") {
      if (strict) throw new Error("refs must be strings");
      continue;
    }
    const r = item.trim();
    if (r === "") continue;
    if (r.length > MAX_PROJECT_REF_LEN) {
      if (strict) throw new Error(`ref must be at most ${MAX_PROJECT_REF_LEN} characters`);
      continue;
    }
    if (seen.has(r)) continue;
    seen.add(r);
    out.push(r);
    if (out.length >= MAX_PROJECT_REFS) {
      if (strict && raw.length > MAX_PROJECT_REFS) throw new Error(`at most ${MAX_PROJECT_REFS} refs are allowed`);
      break;
    }
  }
  return out.length > 0 ? out : undefined;
}

/// Deterministic field-level merge of two surviving entries for the same project name:
/// `note` is governed by `noteAt` (fallback `updatedAt`), `refs` merges per-ref timestamps (`refAts`) associatively
/// and sorts deterministically by `(refAt DESC, name ASC)`.
function mergeProjectEntries(a: ProjectInfoEntry, b: ProjectInfoEntry): ProjectInfoEntry {
  const out: ProjectInfoEntry = {};
  const aHasNote = a.note !== undefined && a.note !== "";
  const bHasNote = b.note !== undefined && b.note !== "";
  if (aHasNote && bHasNote) {
    const aNoteAt = a.noteAt ?? a.updatedAt ?? -1;
    const bNoteAt = b.noteAt ?? b.updatedAt ?? -1;
    const bWins = bNoteAt !== aNoteAt ? bNoteAt > aNoteAt : b.note! > a.note!;
    out.note = bWins ? b.note : a.note;
    const winAt = bWins ? (b.noteAt ?? b.updatedAt) : (a.noteAt ?? a.updatedAt);
    if (winAt !== undefined) out.noteAt = winAt;
  } else if (bHasNote) {
    out.note = b.note;
    const at = b.noteAt ?? b.updatedAt;
    if (at !== undefined) out.noteAt = at;
  } else if (aHasNote) {
    out.note = a.note;
    const at = a.noteAt ?? a.updatedAt;
    if (at !== undefined) out.noteAt = at;
  }
  const mergedRefAts = emptyRefAtsMap();
  let hasAnyRefAt = false;
  const addRefs = (e: ProjectInfoEntry) => {
    if (!e.refs || e.refs.length === 0) return;
    const fallback = e.refsAt ?? e.updatedAt;
    for (const r of e.refs) {
      const own = e.refAts?.[r];
      const hasAt = own !== undefined || fallback !== undefined;
      if (hasAt) hasAnyRefAt = true;
      const rAt = own ?? fallback ?? -1;
      const prev = mergedRefAts[r];
      if (prev === undefined || rAt > prev) mergedRefAts[r] = rAt;
    }
  };
  addRefs(a);
  addRefs(b);
  const sortedRefs = sortRefsByAt(mergedRefAts);
  if (sortedRefs.length > 0) {
    const capped = sortedRefs.slice(0, MAX_PROJECT_REFS);
    out.refs = capped;
    if (hasAnyRefAt) {
      const cleanMap = emptyRefAtsMap();
      let maxRa = -Infinity;
      for (const r of capped) {
        const ra = mergedRefAts[r]!;
        cleanMap[r] = ra;
        if (ra > maxRa) maxRa = ra;
      }
      out.refAts = cleanMap;
      if (Number.isFinite(maxRa) && maxRa >= 0) out.refsAt = maxRa;
    }
  }
  const aAt = a.updatedAt ?? -1;
  const bAt = b.updatedAt ?? -1;
  const maxAt = Math.max(aAt, bAt);
  if (maxAt >= 0 && (a.updatedAt !== undefined || b.updatedAt !== undefined)) out.updatedAt = maxAt;
  return out;
}

function sameEntry(a: ProjectInfoEntry, b: ProjectInfoEntry): boolean {
  if ((a.note ?? "") !== (b.note ?? "")) return false;
  const ar = a.refs ?? [];
  const br = b.refs ?? [];
  if (ar.length !== br.length) return false;
  for (let i = 0; i < ar.length; i++) if (ar[i] !== br[i]) return false;
  return true;
}

export function emptyTombstonesMap(): Record<string, number> {
  return Object.create(null) as Record<string, number>;
}

/// Two-pass parser for `PROJECTS.jsonl`:
/// Pass 1 collects the maximum deletion watermark `maxDelAt[name]` from both `deleted: true` tombstones
/// and `deletedAt` watermarks carried on recreated live entries.
/// Pass 2 drops every live entry with `updatedAt <= maxDelAt[name]` (strictly order-independent across all line orders)
/// and deterministically merges remaining live entries.
export function parseProjectsJsonlWithRaw(
  text: string,
  opts: { strict: boolean },
): { doc: ProjectsInfoDoc; tombstones: Record<string, number>; preservedRawLines: string[] } {
  const projects = emptyProjectsMap();
  const tombstones = emptyTombstonesMap();
  const preservedRawLines: string[] = [];
  const parsedLive: { name: string; entry: ProjectInfoEntry }[] = [];
  const lines = text.split(/\r?\n/);

  // Pass 1: parse lines and collect max deletion watermark per project name.
  for (let i = 0; i < lines.length; i++) {
    const rawLine = lines[i]!;
    const line = rawLine.trim();
    if (line === "") continue;
    let parsed: unknown;
    try {
      parsed = JSON.parse(line);
    } catch (e) {
      if (opts.strict) throw new Error(`corrupt PROJECTS.jsonl at line ${i + 1}: ${(e as Error).message}`);
      log.warn("projects", "preserving unparseable PROJECTS.jsonl line", { line: i + 1, error: (e as Error).message });
      preservedRawLines.push(rawLine);
      continue;
    }
    if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
      if (opts.strict) throw new Error(`corrupt PROJECTS.jsonl at line ${i + 1}: expected JSON object`);
      log.warn("projects", "preserving non-object PROJECTS.jsonl line", { line: i + 1 });
      preservedRawLines.push(rawLine);
      continue;
    }
    const obj = parsed as Record<string, unknown>;
    let name: string;
    try {
      if (typeof obj.name !== "string") throw new Error("missing name");
      name = normalizeProject(obj.name);
      if (name === "") throw new Error("empty name");
    } catch (e) {
      if (opts.strict) throw new Error(`PROJECTS.jsonl line ${i + 1} has invalid project name: ${(e as Error).message}`);
      log.warn("projects", "preserving PROJECTS.jsonl line with invalid name", { line: i + 1 });
      preservedRawLines.push(rawLine);
      continue;
    }
    const updatedAt = typeof obj.updatedAt === "number" && Number.isFinite(obj.updatedAt) ? obj.updatedAt : undefined;
    const noteAt = typeof obj.noteAt === "number" && Number.isFinite(obj.noteAt) ? obj.noteAt : undefined;
    const refsAt = typeof obj.refsAt === "number" && Number.isFinite(obj.refsAt) ? obj.refsAt : undefined;
    const deletedAt = typeof obj.deletedAt === "number" && Number.isFinite(obj.deletedAt) ? obj.deletedAt : undefined;
    const noteClearedAt = typeof obj.noteClearedAt === "number" && Number.isFinite(obj.noteClearedAt) ? obj.noteClearedAt : undefined;
    const refsClearedAt = typeof obj.refsClearedAt === "number" && Number.isFinite(obj.refsClearedAt) ? obj.refsClearedAt : undefined;
    if (obj.deleted === true) {
      const delAt = updatedAt ?? 0;
      const prevDel = tombstones[name];
      if (prevDel === undefined || delAt > prevDel) tombstones[name] = delAt;
      continue;
    }
    if (deletedAt !== undefined) {
      const prevDel = tombstones[name];
      if (prevDel === undefined || deletedAt > prevDel) tombstones[name] = deletedAt;
    }
    const entry: ProjectInfoEntry = {};
    const note = normalizeNote(obj.note);
    if (note !== undefined) {
      entry.note = note;
      const effNoteAt = noteAt ?? updatedAt;
      if (effNoteAt !== undefined) entry.noteAt = effNoteAt;
    }
    const refs = normalizeRefs(obj.refs);
    if (refs !== undefined) {
      entry.refs = refs;
      const effRefsAt = refsAt ?? updatedAt;
      if (effRefsAt !== undefined) entry.refsAt = effRefsAt;
      const rawRefAts = obj.refAts !== null && typeof obj.refAts === "object" && !Array.isArray(obj.refAts)
        ? (obj.refAts as Record<string, unknown>)
        : null;
      const map = emptyRefAtsMap();
      let hasAny = false;
      for (const r of refs) {
        const rawV = rawRefAts !== null && Object.prototype.hasOwnProperty.call(rawRefAts, r) ? rawRefAts[r] : undefined;
        const v = typeof rawV === "number" && Number.isFinite(rawV) ? rawV : effRefsAt;
        if (v !== undefined) {
          map[r] = v;
          hasAny = true;
        }
      }
      if (hasAny) entry.refAts = map;
    }
    if (updatedAt !== undefined) entry.updatedAt = updatedAt;
    if (noteClearedAt !== undefined) entry.noteClearedAt = noteClearedAt;
    if (refsClearedAt !== undefined) entry.refsClearedAt = refsClearedAt;
    parsedLive.push({ name, entry });
  }

  // Filter surviving live rows (at > maxDelAt) and collect per-field clear watermarks (`noteClearedAt` / `refsClearedAt`).
  const surviving: { name: string; entry: ProjectInfoEntry }[] = [];
  const maxNoteCleared = emptyTombstonesMap();
  const maxRefsCleared = emptyTombstonesMap();
  for (const item of parsedLive) {
    const maxDel = tombstones[item.name];
    if (maxDel !== undefined && (item.entry.updatedAt ?? -1) <= maxDel) continue;
    surviving.push(item);
    if (item.entry.noteClearedAt !== undefined) {
      const prev = maxNoteCleared[item.name];
      if (prev === undefined || item.entry.noteClearedAt > prev) maxNoteCleared[item.name] = item.entry.noteClearedAt;
    }
    if (item.entry.refsClearedAt !== undefined) {
      const prev = maxRefsCleared[item.name];
      if (prev === undefined || item.entry.refsClearedAt > prev) maxRefsCleared[item.name] = item.entry.refsClearedAt;
    }
  }

  // Pass 2: filter fields older than or equal to max(clear watermark, project deletion watermark)
  // using `noteAt` and per-ref `refAts`, then merge remaining live entries independently per field.
  for (const { name, entry } of surviving) {
    const delCut = tombstones[name];
    const nc = maxNoteCleared[name];
    const rc = maxRefsCleared[name];
    const noteCut = nc !== undefined && delCut !== undefined ? Math.max(nc, delCut) : (nc ?? delCut);
    const refsCut = rc !== undefined && delCut !== undefined ? Math.max(rc, delCut) : (rc ?? delCut);
    const effNoteAt = entry.noteAt ?? entry.updatedAt ?? -1;
    const filtered: ProjectInfoEntry = {};
    if (entry.note !== undefined && (noteCut === undefined || effNoteAt > noteCut)) {
      filtered.note = entry.note;
      if (entry.noteAt !== undefined) filtered.noteAt = entry.noteAt;
      else if (entry.updatedAt !== undefined) filtered.noteAt = entry.updatedAt;
    }
    if (entry.refs !== undefined && entry.refs.length > 0) {
      const keptRefs: string[] = [];
      const keptRefAts = emptyRefAtsMap();
      let maxRa = -Infinity;
      let hasAnyRa = false;
      for (const r of entry.refs) {
        const own = entry.refAts?.[r];
        const fallback = entry.refsAt ?? entry.updatedAt;
        const rAt = own ?? fallback ?? -1;
        if (refsCut !== undefined && rAt <= refsCut) continue;
        keptRefs.push(r);
        if (own !== undefined || fallback !== undefined) {
          keptRefAts[r] = rAt;
          hasAnyRa = true;
          if (rAt > maxRa) maxRa = rAt;
        }
      }
      if (keptRefs.length > 0) {
        filtered.refs = keptRefs;
        if (hasAnyRa) {
          filtered.refAts = keptRefAts;
          if (Number.isFinite(maxRa) && maxRa >= 0) filtered.refsAt = maxRa;
        }
      }
    }
    if (entry.updatedAt !== undefined) filtered.updatedAt = entry.updatedAt;
    const prev = projects[name];
    projects[name] = prev === undefined ? mergeProjectEntries(filtered, {}) : mergeProjectEntries(prev, filtered);
  }
  for (const name of Object.keys(projects)) {
    const nc = maxNoteCleared[name];
    if (nc !== undefined) projects[name]!.noteClearedAt = nc;
    const rc = maxRefsCleared[name];
    if (rc !== undefined) projects[name]!.refsClearedAt = rc;
  }
  return { doc: { projects }, tombstones, preservedRawLines };
}

export function parseProjectsJsonl(text: string, opts: { strict: boolean }): ProjectsInfoDoc {
  return parseProjectsJsonlWithRaw(text, opts).doc;
}

/// Serializes `ProjectsInfoDoc` (plus optional deletion watermarks/tombstones) into canonical JSONL (sorted by UTF-8 bytes of `name`,
/// one compact object per line), appending any `preservedRawLines` verbatim at the end.
/// Live projects carry `noteAt`, per-ref `refAts`/`refsAt`, prior `deletedAt`, and field-level `noteClearedAt`/`refsClearedAt` watermarks
/// so stale versions from lagging peers can never resurrect deleted projects or cleared metadata.
/// Throws if serialized UTF-8 byte length exceeds `FILE_MOST` (512 KiB).
export function serializeProjectsJsonl(
  doc: ProjectsInfoDoc,
  preservedRawLines: readonly string[] = [],
  tombstones: Record<string, number> = emptyTombstonesMap(),
): string {
  const allNames = new Set<string>([...Object.keys(doc.projects), ...Object.keys(tombstones)]);
  const names = [...allNames].sort(byBytes);
  const lines: string[] = [];
  for (const name of names) {
    const e = doc.projects[name];
    const delAt = tombstones[name];
    if (e) {
      const rec: Record<string, unknown> = { name };
      if (e.note !== undefined && e.note !== "") {
        rec.note = e.note;
        const na = e.noteAt ?? e.updatedAt;
        if (typeof na === "number" && Number.isFinite(na)) rec.noteAt = na;
      }
      if (e.refs !== undefined && e.refs.length > 0) {
        const refMap = emptyRefAtsMap();
        let hasAnyRa = false;
        for (const r of e.refs) {
          const v = e.refAts?.[r] ?? e.refsAt ?? e.updatedAt;
          if (typeof v === "number" && Number.isFinite(v)) {
            refMap[r] = v;
            hasAnyRa = true;
          } else {
            refMap[r] = -1;
          }
        }
        const sortedRefs = sortRefsByAt(refMap);
        rec.refs = sortedRefs;
        if (hasAnyRa) {
          let maxRa = -Infinity;
          const orderedAts: Record<string, number> = {};
          for (const r of sortedRefs) {
            const v = refMap[r]!;
            orderedAts[r] = v;
            if (v > maxRa) maxRa = v;
          }
          if (Number.isFinite(maxRa) && maxRa >= 0) rec.refsAt = maxRa;
          rec.refAts = orderedAts;
        }
      }
      if (typeof e.updatedAt === "number" && Number.isFinite(e.updatedAt)) rec.updatedAt = e.updatedAt;
      if (typeof delAt === "number" && Number.isFinite(delAt)) rec.deletedAt = delAt;
      if (typeof e.noteClearedAt === "number" && Number.isFinite(e.noteClearedAt)) rec.noteClearedAt = e.noteClearedAt;
      if (typeof e.refsClearedAt === "number" && Number.isFinite(e.refsClearedAt)) rec.refsClearedAt = e.refsClearedAt;
      lines.push(JSON.stringify(rec));
      continue;
    }
    if (typeof delAt === "number" && Number.isFinite(delAt)) {
      lines.push(JSON.stringify({ name, deleted: true, updatedAt: delAt }));
    }
  }
  for (const raw of preservedRawLines) {
    if (raw.trim() !== "") lines.push(raw);
  }
  const text = lines.length === 0 ? "" : `${lines.join("\n")}\n`;
  if (Buffer.byteLength(text, "utf8") > FILE_MOST) {
    throw new Error(`PROJECTS.jsonl exceeds maximum size (${FILE_MOST} bytes)`);
  }
  return text;
}

/// Pure path resolution for workspace `ws`'s `PROJECTS.jsonl` (NEVER creates directories on disk).
export function projectsInfoPath(agentHome: string, ws: string | null, home: string | null): string {
  return join(workspaceAgentHomePath(agentHome, ws, home), PROJECTS_INFO_FILE);
}

/// Strict read: ONLY `ENOENT` returns an empty document. Corrupt JSONL, unreadable files, or >512 KiB throw.
/// When `opts.skipPrivate` is true, `0600` private files return empty so private projects never leak to peers.
export async function readProjectsInfoStrict(
  agentHome: string,
  ws: string | null,
  home: string | null,
  opts?: ReadProjectsOpts,
): Promise<ProjectsInfoDoc> {
  const path = projectsInfoPath(agentHome, ws, home);
  let st;
  try {
    st = await stat(path);
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code === "ENOENT") return { projects: emptyProjectsMap() };
    throw e;
  }
  if (opts?.skipPrivate && isOwnPrivateMode(st.mode)) return { projects: emptyProjectsMap() };
  if (st.size > FILE_MOST) throw new Error(`PROJECTS.jsonl exceeds maximum size (${FILE_MOST} bytes)`);
  const text = await readFile(path, "utf8");
  if (Buffer.byteLength(text, "utf8") > FILE_MOST) throw new Error(`PROJECTS.jsonl exceeds maximum size (${FILE_MOST} bytes)`);
  return parseProjectsJsonl(text, { strict: true });
}

/// Best-effort read for non-blocking agent hints/summaries: skips corrupt lines with a warning, never throws on corruption.
export async function readProjectsInfoBestEffort(
  agentHome: string,
  ws: string | null,
  home: string | null,
  opts?: ReadProjectsOpts,
): Promise<ProjectsInfoDoc> {
  const path = projectsInfoPath(agentHome, ws, home);
  try {
    const st = await stat(path);
    if (opts?.skipPrivate && isOwnPrivateMode(st.mode)) return { projects: emptyProjectsMap() };
    if (st.size > FILE_MOST) {
      log.warn("projects", "PROJECTS.jsonl exceeds size limit; ignoring for hints", { path, size: st.size });
      return { projects: emptyProjectsMap() };
    }
    const text = await readFile(path, "utf8");
    return parseProjectsJsonl(text, { strict: false });
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code !== "ENOENT") {
      log.warn("projects", "could not read PROJECTS.jsonl for hints", { path, error: (e as Error).message });
    }
    return { projects: emptyProjectsMap() };
  }
}

/// Lenient read for member UI (`GET /projects/info`): enforces 512 KiB and permission errors,
/// but skips malformed lines and reports `corruptLines` count instead of returning 500.
export async function readProjectsInfoLenient(
  agentHome: string,
  ws: string | null,
  home: string | null,
  opts?: ReadProjectsOpts,
): Promise<ProjectsInfoDoc & { corruptLines: number }> {
  const path = projectsInfoPath(agentHome, ws, home);
  let st;
  try {
    st = await stat(path);
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code === "ENOENT") return { projects: emptyProjectsMap(), corruptLines: 0 };
    throw e;
  }
  if (opts?.skipPrivate && isOwnPrivateMode(st.mode)) return { projects: emptyProjectsMap(), corruptLines: 0 };
  if (st.size > FILE_MOST) throw new Error(`PROJECTS.jsonl exceeds maximum size (${FILE_MOST} bytes)`);
  const text = await readFile(path, "utf8");
  if (Buffer.byteLength(text, "utf8") > FILE_MOST) throw new Error(`PROJECTS.jsonl exceeds maximum size (${FILE_MOST} bytes)`);
  const { doc, preservedRawLines } = parseProjectsJsonlWithRaw(text, { strict: false });
  return { ...doc, corruptLines: preservedRawLines.length };
}

/// Backwards-compatible alias for strict read.
export const readProjectsInfo = readProjectsInfoStrict;

type FileSnap = { exists: boolean; mtimeMs: number; size: number; mode: number };

async function readProjectsForWrite(path: string): Promise<{ doc: ProjectsInfoDoc; tombstones: Record<string, number>; preservedRawLines: string[]; snap: FileSnap }> {
  let st;
  try {
    st = await stat(path);
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code === "ENOENT") {
      return { doc: { projects: emptyProjectsMap() }, tombstones: emptyTombstonesMap(), preservedRawLines: [], snap: { exists: false, mtimeMs: 0, size: 0, mode: 0o644 } };
    }
    throw e;
  }
  if (st.size > FILE_MOST) throw new Error(`PROJECTS.jsonl exceeds maximum size (${FILE_MOST} bytes)`);
  const text = await readFile(path, "utf8");
  if (Buffer.byteLength(text, "utf8") > FILE_MOST) throw new Error(`PROJECTS.jsonl exceeds maximum size (${FILE_MOST} bytes)`);
  const { doc, tombstones, preservedRawLines } = parseProjectsJsonlWithRaw(text, { strict: false });
  return { doc, tombstones, preservedRawLines, snap: { exists: true, mtimeMs: st.mtimeMs, size: st.size, mode: st.mode & 0o777 } };
}

async function statMatches(path: string, snap: FileSnap): Promise<boolean> {
  try {
    const st = await stat(path);
    return snap.exists && st.mtimeMs === snap.mtimeMs && st.size === snap.size && (st.mode & 0o777) === snap.mode;
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code === "ENOENT") return !snap.exists;
    return false;
  }
}

async function writeProjectsFileUnlocked(
  path: string,
  doc: ProjectsInfoDoc,
  preservedRawLines: readonly string[],
  snap: FileSnap,
  tombstones: Record<string, number>,
): Promise<ProjectsInfoDoc> {
  const text = serializeProjectsJsonl(doc, preservedRawLines, tombstones);
  await mkdir(dirname(path), { recursive: true });
  // Preserve owner-only private permissions (e.g. 0600) so private files are never silently widened to 0644.
  const targetMode = snap.exists && isOwnPrivateMode(snap.mode) ? snap.mode : 0o644;
  const tmp = `${path}.tmp.${process.pid}.${Math.random().toString(36).slice(2, 8)}`;
  await writeFile(tmp, text, { mode: targetMode });
  await chmod(tmp, targetMode).catch(() => {});
  await rename(tmp, path);
  return doc;
}

const MAX_STAT_RETRIES = 3;

/// Upserts or deletes a single project's info entry in `PROJECTS.jsonl` (serialized per file, preserves unknown/corrupt lines & 0600 mode).
/// Deletes write a tombstone (`deleted: true, updatedAt: now`) so stale proposal replays cannot resurrect deleted projects.
/// If normalized `note` and `refs` are unchanged on an existing entry, does NOT bump `updatedAt` or rewrite.
export async function updateProjectInfo(
  agentHome: string,
  ws: string | null,
  home: string | null,
  input: { name: string; note?: string | null; refs?: string[] | null; delete?: boolean; now: number },
): Promise<{ doc: ProjectsInfoDoc; changed: boolean }> {
  const name = normalizeProject(input.name);
  if (name === "") throw new Error("project name is required");
  const path = projectsInfoPath(agentHome, ws, home);
  return withProjectsFileLock(path, async () => {
    for (let attempt = 0; attempt < MAX_STAT_RETRIES; attempt++) {
      const { doc, tombstones, preservedRawLines, snap } = await readProjectsForWrite(path);
      const existing = doc.projects[name];
      if (input.delete === true) {
        const delAt = Math.max(input.now, maxEntryTimestamp(existing), tombstones[name] ?? -Infinity);
        if (existing === undefined && tombstones[name] !== undefined && tombstones[name]! >= delAt) {
          return { doc, changed: false };
        }
        delete doc.projects[name];
        tombstones[name] = delAt;
        if (!(await statMatches(path, snap))) continue;
        await writeProjectsFileUnlocked(path, doc, preservedRawLines, snap, tombstones);
        return { doc, changed: true };
      }
      const next: ProjectInfoEntry = existing ? { ...existing } : {};
      let noteCleared = false;
      let refsCleared = false;
      let noteSet = false;
      let refsSet = false;
      if (input.note !== undefined) {
        const n = input.note === null ? undefined : normalizeNote(input.note, true);
        if (n !== undefined) {
          next.note = n;
          noteSet = true;
        } else {
          delete next.note;
          delete next.noteAt;
          noteCleared = true;
        }
      }
      if (input.refs !== undefined) {
        const r = input.refs === null ? undefined : normalizeRefs(input.refs, true);
        if (r !== undefined) {
          next.refs = r;
          refsSet = true;
        } else {
          delete next.refs;
          delete next.refsAt;
          delete next.refAts;
          refsCleared = true;
        }
      }
      // Explicit clear on a locally empty field must still persist `noteClearedAt` / `refsClearedAt`
      // unless an equal or newer clear watermark is already recorded.
      const needsNoteClearWrite = noteCleared && (existing === undefined || existing.note !== undefined || existing.noteClearedAt === undefined || existing.noteClearedAt < input.now);
      const needsRefsClearWrite = refsCleared && (existing === undefined || existing.refs !== undefined || existing.refsClearedAt === undefined || existing.refsClearedAt < input.now);
      if (existing !== undefined && sameEntry(existing, next) && !needsNoteClearWrite && !needsRefsClearWrite) {
        return { doc, changed: false };
      }
      // Ensure writeAt strictly exceeds all existing timestamps on this entry and any prior deletion watermark.
      const prevDel = tombstones[name];
      const existingMax = maxEntryTimestamp(existing);
      let writeAt = Math.max(
        input.now,
        Number.isFinite(existingMax) ? existingMax + 1 : -Infinity,
        prevDel !== undefined ? prevDel + 1 : -Infinity,
      );
      if (noteSet) next.noteAt = writeAt;
      if (noteCleared) next.noteClearedAt = Math.max(next.noteClearedAt ?? -Infinity, writeAt);
      if (refsSet && next.refs !== undefined) {
        const prevRefs = existing?.refs ?? [];
        const removedAny = prevRefs.some((oldR) => !next.refs!.includes(oldR));
        const newRefAts = emptyRefAtsMap();
        if (removedAny) {
          next.refsClearedAt = Math.max(next.refsClearedAt ?? -Infinity, writeAt);
          writeAt = writeAt + 1;
          for (const r of next.refs) newRefAts[r] = writeAt;
          next.refsAt = writeAt;
        } else {
          let maxRa = writeAt;
          for (const r of next.refs) {
            const oldAt = existing?.refAts?.[r] ?? (prevRefs.includes(r) ? (existing?.refsAt ?? existing?.updatedAt) : undefined);
            const ra = oldAt !== undefined ? oldAt : writeAt;
            newRefAts[r] = ra;
            if (ra > maxRa) maxRa = ra;
          }
          next.refsAt = maxRa;
        }
        next.refAts = newRefAts;
        next.refs = sortRefsByAt(newRefAts);
      }
      if (refsCleared) next.refsClearedAt = Math.max(next.refsClearedAt ?? -Infinity, writeAt);
      next.updatedAt = writeAt;
      doc.projects[name] = next;
      if (!(await statMatches(path, snap))) continue;
      await writeProjectsFileUnlocked(path, doc, preservedRawLines, snap, tombstones);
      return { doc, changed: true };
    }
    throw new Error("PROJECTS.jsonl changed concurrently too many times");
  });
}

/// Applies a resolved proposal's metadata intent inside `withProjectsFileLock` + `statMatches` retry loop.
/// Supports tri-state `note` / `refs`: `undefined` preserves existing value, `null` explicitly clears it, value overwrites it.
/// Evaluates `note` and `refs` independently against `input.resolvedAt` (only project-level tombstone skips the whole entry).
export async function applyProposalInfoSync(
  agentHome: string,
  ws: string | null,
  home: string | null,
  input: { name: string; note?: string | null; refs?: string[] | null; resolvedAt: number; isReplay: boolean },
): Promise<{ doc: ProjectsInfoDoc; changed: boolean; skipped: boolean }> {
  const name = normalizeProject(input.name);
  if (name === "") throw new Error("project name is required");
  const path = projectsInfoPath(agentHome, ws, home);
  return withProjectsFileLock(path, async () => {
    for (let attempt = 0; attempt < MAX_STAT_RETRIES; attempt++) {
      const { doc, tombstones, preservedRawLines, snap } = await readProjectsForWrite(path);
      const delAt = tombstones[name];
      if (delAt !== undefined && delAt >= input.resolvedAt) {
        return { doc, changed: false, skipped: true };
      }
      const existing = doc.projects[name];
      const delta: Record<string, unknown> = { name };
      let deltaUpdatedAt = input.resolvedAt;

      if (input.note !== undefined) {
        const normalizedNote = input.note === null ? undefined : normalizeNote(input.note, true);
        if (normalizedNote === undefined) {
          delta.noteClearedAt = input.resolvedAt;
        } else {
          delta.note = normalizedNote;
          delta.noteAt = input.resolvedAt;
        }
      }

      if (input.refs !== undefined) {
        const normalizedRefs = input.refs === null ? undefined : normalizeRefs(input.refs, true);
        if (normalizedRefs === undefined) {
          delta.refsClearedAt = input.resolvedAt;
        } else {
          delta.refsClearedAt = input.resolvedAt;
          const approvedAt = input.resolvedAt + 1;
          delta.refs = normalizedRefs;
          delta.refsAt = approvedAt;
          delta.refAts = Object.fromEntries(normalizedRefs.map((r) => [r, approvedAt]));
          deltaUpdatedAt = Math.max(deltaUpdatedAt, approvedAt);
        }
      }

      delta.updatedAt = deltaUpdatedAt;

      const singleProjects = emptyProjectsMap();
      if (existing !== undefined) singleProjects[name] = existing;
      const singleTombstones = emptyTombstonesMap();
      if (delAt !== undefined) singleTombstones[name] = delAt;
      const beforeSingle = serializeProjectsJsonl({ projects: singleProjects }, [], singleTombstones);
      const mergedSingle = parseProjectsJsonlWithRaw(`${beforeSingle}${JSON.stringify(delta)}\n`, { strict: true });
      const afterSingle = serializeProjectsJsonl(mergedSingle.doc, [], mergedSingle.tombstones);
      if (afterSingle === beforeSingle && existing !== undefined) {
        return { doc, changed: false, skipped: false };
      }
      const mergedEntry = mergedSingle.doc.projects[name];
      if (mergedEntry !== undefined) doc.projects[name] = mergedEntry;
      if (mergedSingle.tombstones[name] !== undefined) tombstones[name] = mergedSingle.tombstones[name]!;
      if (!(await statMatches(path, snap))) continue;
      await writeProjectsFileUnlocked(path, doc, preservedRawLines, snap, tombstones);
      return { doc, changed: true, skipped: false };
    }
    throw new Error("PROJECTS.jsonl changed concurrently too many times");
  });
}

/// Ensures `name` is registered in `PROJECTS.jsonl` (optionally updating note/refs); no-op if already registered with same metadata.
export async function ensureProjectRegistered(
  agentHome: string,
  ws: string | null,
  home: string | null,
  input: { name: string; note?: string; refs?: string[]; now: number },
): Promise<{ doc: ProjectsInfoDoc; changed: boolean }> {
  return updateProjectInfo(agentHome, ws, home, input);
}

/// Renames or merges a project's info entry (`from` -> `to`) in `PROJECTS.jsonl` (serialized per file).
/// When `opts.createIfMissing` is false and `from` is absent from `PROJECTS.jsonl`, does NOT fabricate `to`.
export async function renameProjectInfo(
  agentHome: string,
  ws: string | null,
  home: string | null,
  fromRaw: string,
  toRaw: string,
  now: number,
  opts?: { createIfMissing?: boolean },
): Promise<{ doc: ProjectsInfoDoc; changed: boolean }> {
  const from = normalizeProject(fromRaw);
  const to = normalizeProject(toRaw);
  if (from === "") throw new Error("source project name is required");
  const createIfMissing = opts?.createIfMissing !== false;
  const path = projectsInfoPath(agentHome, ws, home);
  return withProjectsFileLock(path, async () => {
    for (let attempt = 0; attempt < MAX_STAT_RETRIES; attempt++) {
      const { doc, tombstones, preservedRawLines, snap } = await readProjectsForWrite(path);
      const src = doc.projects[from];
      if (src === undefined) {
        if (!createIfMissing || to === "" || to in doc.projects) return { doc, changed: false };
        const prevDel = tombstones[to];
        doc.projects[to] = { updatedAt: prevDel !== undefined && now <= prevDel ? prevDel + 1 : now };
        if (!(await statMatches(path, snap))) continue;
        await writeProjectsFileUnlocked(path, doc, preservedRawLines, snap, tombstones);
        return { doc, changed: true };
      }
      delete doc.projects[from];
      const srcMax = maxEntryTimestamp(src);
      tombstones[from] = Math.max(now, srcMax, tombstones[from] ?? -Infinity);
      if (to !== "") {
        const prevDel = tombstones[to];
        const dst = doc.projects[to];
        const dstMax = maxEntryTimestamp(dst);
        const nextAt = Math.max(
          now,
          Number.isFinite(srcMax) ? srcMax + 1 : -Infinity,
          Number.isFinite(dstMax) ? dstMax + 1 : -Infinity,
          prevDel !== undefined ? prevDel + 1 : -Infinity,
        );
        if (dst === undefined) {
          const moved: ProjectInfoEntry = { ...src, updatedAt: nextAt };
          if (moved.note !== undefined && moved.note !== "") moved.noteAt = nextAt;
          if (moved.refs !== undefined && moved.refs.length > 0) {
            const refAts = emptyRefAtsMap();
            for (const r of moved.refs) refAts[r] = nextAt;
            moved.refAts = refAts;
            moved.refs = sortRefsByAt(refAts);
            moved.refsAt = nextAt;
          }
          doc.projects[to] = moved;
        } else {
          const merged: ProjectInfoEntry = { updatedAt: nextAt };
          const notes = [dst.note, src.note].filter((n): n is string => typeof n === "string" && n !== "");
          if (notes.length > 0) {
            const joined = [...new Set(notes)].join("\n");
            merged.note = joined.length > MAX_PROJECT_NOTE ? joined.slice(0, MAX_PROJECT_NOTE) : joined;
            merged.noteAt = nextAt;
          }
          const refs = normalizeRefs([...(dst.refs ?? []), ...(src.refs ?? [])]);
          if (refs !== undefined) {
            const refAts = emptyRefAtsMap();
            for (const r of refs) refAts[r] = nextAt;
            merged.refAts = refAts;
            merged.refs = sortRefsByAt(refAts);
            merged.refsAt = nextAt;
          }
          const nc = Math.max(dst.noteClearedAt ?? -Infinity, src.noteClearedAt ?? -Infinity);
          if (Number.isFinite(nc)) merged.noteClearedAt = nc;
          const rc = Math.max(dst.refsClearedAt ?? -Infinity, src.refsClearedAt ?? -Infinity);
          if (Number.isFinite(rc)) merged.refsClearedAt = rc;
          doc.projects[to] = merged;
        }
      }
      if (!(await statMatches(path, snap))) continue;
      await writeProjectsFileUnlocked(path, doc, preservedRawLines, snap, tombstones);
      return { doc, changed: true };
    }
    throw new Error("PROJECTS.jsonl changed concurrently too many times");
  });
}
