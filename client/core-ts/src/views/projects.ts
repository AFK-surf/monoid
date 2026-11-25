// Workspace project & tag summaries (`projects`, `project`, `tags` topics), `PROJECTS.jsonl` info sync/caching,
// and project/classification operations (`chat.classify`, `proposal.resolve`, `project.updateInfo`, `project.rename`, `project.merge`).
import { Effect } from "effect";
import type { Inner } from "../core.ts";
import type { Call } from "../core/calls.ts";
import { handlers } from "../core/execute.ts";
import type { Data } from "../data.ts";
import { CHAT_READS } from "../db/chat-reads.ts";
import { CoreError } from "../error.ts";
import { stationFeature } from "../features.ts";
import { t } from "../i18n.ts";
import { StationAddr } from "../station/addr.ts";
import { Priority } from "../sync/scheduler.ts";
import { arr as arrU, get, isObject } from "../util.ts";
import { ofAddress } from "../workspace.ts";
import { fromBeforeRoute } from "./presets.ts";

// deno-lint-ignore no-explicit-any
type J = any;
const arr = (v: unknown): J[] => arrU(v) ?? [];
const str = (v: unknown): string | null => (typeof v === "string" && v !== "" ? v : null);
const defaultCollate = (a: string, b: string) => (a < b ? -1 : a > b ? 1 : 0);

export type HostCollate = (names: readonly string[]) => number[] | null;

/// Builds a locale-aware string comparator from the host's batch `collate(names)` hook, falling back to code-unit order.
export function makeCollator(names: readonly string[], collate?: HostCollate): (a: string, b: string) => number {
  if (collate !== undefined && names.length > 0) {
    const ranks = collate(names);
    if (ranks !== null && ranks.length === names.length) {
      const map = new Map<string, number>();
      for (let i = 0; i < names.length; i++) map.set(names[i]!, ranks[i]!);
      return (a, b) => {
        const ra = map.get(a);
        const rb = map.get(b);
        if (ra !== undefined && rb !== undefined && ra !== rb) return ra - rb;
        return a < b ? -1 : a > b ? 1 : 0;
      };
    }
  }
  return defaultCollate;
}

/// Single-page UTF-8 byte budget for `projects` and `tags` topics (strictly below the 32 KiB wire cap).
export const PAGE_BYTE_BUDGET = 28 * 1024;
/// Unified single-page UTF-8 byte budget for `project` detail view (page 1 & multi-ref continuation pages),
/// ensuring any note shrink/expand or ref edit stays strictly within the 4 KiB `{ id, delta }` wire budget.
const DETAIL_PAGE_BUDGET = 3400;
/// Single-ref continuation page budget when a lone ref is the sole payload (`refs.length === 0 && noteChunk === undefined`),
/// allowing an 80-CJK project name + 512-char `\u0001` ref (~3,454 B) without truncation while staying <= 4,096 B wire frame.
const DETAIL_SINGLE_REF_BUDGET = 3800;
/// Maximum UTF-8 JSON-encoded bytes for a single page's `note` slice in `project` detail view.
const DETAIL_NOTE_PAGE_BYTES = 3200;
/// Maximum UTF-8 bytes for a single truncated item name/ref when an individual entry would otherwise exceed budget.
const MIN_ITEM_TEXT_BYTES = 64;
/// Maximum bounded LRU pagination snapshots retained per `(Data, kind, scope)` so dynamic reorders never drop or duplicate items.
const MAX_PAGE_SNAPSHOTS = 16;

const enc = new TextEncoder();
const utf8Bytes = (v: unknown): number => enc.encode(JSON.stringify(v)).length;

/// Slices `s` starting at UTF-16 code-unit `start` so that `JSON.stringify(chunk)` is at most `maxBytes` UTF-8 bytes,
/// never splitting a UTF-16 surrogate pair.
function sliceJsonString(s: string, start: number, maxBytes: number): { chunk: string; nextOffset: number } {
  const from = Math.max(0, Math.min(start, s.length));
  if (from >= s.length) return { chunk: "", nextOffset: s.length };
  const tail = s.slice(from);
  if (utf8Bytes(tail) <= maxBytes) return { chunk: tail, nextOffset: s.length };
  const budget = Math.max(8, maxBytes);
  let lo = 0;
  let hi = s.length - from;
  while (lo < hi) {
    let mid = (lo + hi + 1) >> 1;
    if (mid > 0 && from + mid < s.length) {
      const code = s.charCodeAt(from + mid - 1);
      if (code >= 0xd800 && code <= 0xdbff) mid--;
    }
    if (mid <= lo) break;
    if (utf8Bytes(s.slice(from, from + mid)) <= budget) lo = mid;
    else hi = mid - 1;
  }
  if (lo === 0) {
    // Advance by at least one full code point so pagination always makes progress.
    const code = s.charCodeAt(from);
    lo = code >= 0xd800 && code <= 0xdbff && from + 1 < s.length ? 2 : 1;
  } else if (from + lo < s.length) {
    const code = s.charCodeAt(from + lo - 1);
    if (code >= 0xd800 && code <= 0xdbff) lo--;
  }
  return { chunk: s.slice(from, from + lo), nextOffset: from + lo };
}

/// Truncates a string to at most `maxBytes` UTF-8 bytes (accounting for JSON string escaping via `utf8Bytes`),
/// never splitting a UTF-16 surrogate pair, and appends `"…"` when truncated.
function truncateJsonString(s: string, maxBytes: number): string {
  if (utf8Bytes(s) <= maxBytes) return s;
  const budget = Math.max(8, maxBytes);
  let lo = 0;
  let hi = s.length;
  while (lo < hi) {
    let mid = (lo + hi + 1) >> 1;
    // Avoid splitting a surrogate pair
    if (mid > 0 && mid < s.length) {
      const code = s.charCodeAt(mid - 1);
      if (code >= 0xd800 && code <= 0xdbff) mid--;
    }
    if (mid <= lo) break;
    const candidate = `${s.slice(0, mid)}…`;
    if (utf8Bytes(candidate) <= budget) lo = mid;
    else hi = mid - 1;
  }
  if (lo > 0 && lo < s.length) {
    const code = s.charCodeAt(lo - 1);
    if (code >= 0xd800 && code <= 0xdbff) lo--;
  }
  return lo === 0 ? "…" : `${s.slice(0, lo)}…`;
}

/// The `choice` record where a workspace's cached `PROJECTS.jsonl` metadata map is persisted for offline use.
export const projectsInfoKey = (ws: string): string => `ws:${ws}:projectsInfo`;
/// The `choice` record where per-station `PROJECTS.jsonl` snapshots are persisted across restarts.
export const projectsInfoByStationKey = (ws: string): string => `ws:${ws}:projectsInfoByStation`;

export type CachedProjectInfo = {
  note?: string;
  refs?: string[];
  updatedAt?: number;
};

export type CachedProjectsInfoMap = Record<string, CachedProjectInfo>;

function emptyMap(): CachedProjectsInfoMap {
  return Object.create(null) as CachedProjectsInfoMap;
}

function normalizeInfoMap(raw: unknown): CachedProjectsInfoMap {
  const out = emptyMap();
  if (!isObject(raw)) return out;
  for (const name of Object.keys(raw)) {
    if (!Object.hasOwn(raw, name) || name === "") continue;
    const entry = raw[name];
    if (!isObject(entry)) continue;
    const item: CachedProjectInfo = {};
    if (typeof entry.note === "string" && entry.note.trim() !== "") item.note = entry.note.trim();
    if (Array.isArray(entry.refs)) {
      const refs = entry.refs.filter((r): r is string => typeof r === "string" && r.trim() !== "").map((r) => r.trim());
      if (refs.length > 0) item.refs = refs;
    }
    if (typeof entry.updatedAt === "number" && Number.isFinite(entry.updatedAt)) item.updatedAt = entry.updatedAt;
    out[name] = item;
  }
  return out;
}

/// Merges `incoming` from a station GET into `prev` by per-project `updatedAt` (an empty station never wipes cached info).
export function mergeProjectsInfoMaps(prev: CachedProjectsInfoMap, incoming: CachedProjectsInfoMap): CachedProjectsInfoMap {
  const out = emptyMap();
  for (const name of Object.keys(prev)) {
    if (Object.hasOwn(prev, name)) out[name] = prev[name]!;
  }
  for (const name of Object.keys(incoming)) {
    if (!Object.hasOwn(incoming, name)) continue;
    const next = incoming[name]!;
    const cur = Object.hasOwn(out, name) ? out[name] : undefined;
    if (cur === undefined || (next.updatedAt ?? 0) >= (cur.updatedAt ?? 0)) {
      out[name] = next;
    }
  }
  return out;
}

function toPlainObject(map: CachedProjectsInfoMap): Record<string, CachedProjectInfo> {
  const out: Record<string, CachedProjectInfo> = Object.create(null);
  for (const k of Object.keys(map).sort()) {
    if (Object.hasOwn(map, k)) out[k] = map[k]!;
  }
  return out;
}

type PageSnap = { id: string; names: readonly string[] };
const pageSnapshots = new WeakMap<Data, Map<string, PageSnap[]>>();

/// Deterministic 64-bit (2x32-bit FNV-1a) content hash of an ordered list of names so identical first-page recomputes
/// produce the exact same `nextCursor` (zero spurious deltas, zero LRU churn).
function hashOrderedNames(names: readonly string[]): string {
  let h1 = 0x811c9dc5;
  let h2 = 0x01000193;
  const s = names.join("\0");
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i);
    h1 ^= c;
    h1 = Math.imul(h1, 0x01000193);
    h2 ^= c ^ (i & 0xff);
    h2 = Math.imul(h2, 0x01000193);
  }
  return `${(h1 >>> 0).toString(16).padStart(8, "0")}${(h2 >>> 0).toString(16).padStart(8, "0")}`;
}

function savePageSnapshot(data: Data, bucket: string, names: readonly string[]): string {
  let byBucket = pageSnapshots.get(data);
  if (byBucket === undefined) {
    byBucket = new Map();
    pageSnapshots.set(data, byBucket);
  }
  let list = byBucket.get(bucket);
  if (list === undefined) {
    list = [];
    byBucket.set(bucket, list);
  }
  const id = hashOrderedNames(names);
  const existingIdx = list.findIndex((s) => s.id === id);
  if (existingIdx !== -1) {
    const [hit] = list.splice(existingIdx, 1);
    list.push(hit!);
    return id;
  }
  list.push({ id, names });
  if (list.length > MAX_PAGE_SNAPSHOTS) list.shift();
  return id;
}

function getPageSnapshot(data: Data, bucket: string, id: string): PageSnap | undefined {
  const list = pageSnapshots.get(data)?.get(bucket);
  if (list === undefined) return undefined;
  const idx = list.findIndex((s) => s.id === id);
  if (idx === -1) return undefined;
  const [hit] = list.splice(idx, 1);
  list.push(hit!);
  return hit;
}

function parseSnapCursor(cursor: unknown): { snapId: string; offset: number } | null {
  if (typeof cursor !== "string" || !cursor.startsWith("s:")) return null;
  const second = cursor.indexOf(":", 2);
  if (second === -1) return null;
  const snapId = cursor.slice(2, second);
  const offStr = cursor.slice(second + 1);
  if (snapId === "" || !/^\d+$/.test(offStr)) return null;
  const offset = Number(offStr);
  return Number.isSafeInteger(offset) && offset >= 0 ? { snapId, offset } : null;
}

function parseDetailCursor(cursor: unknown): { kind: "note" | "refs"; offset: number } {
  if (typeof cursor !== "string" || cursor === "") return { kind: "note", offset: 0 };
  if (cursor.startsWith("n:")) {
    const rest = cursor.slice(2);
    if (/^\d+$/.test(rest)) {
      const n = Number(rest);
      if (Number.isSafeInteger(n) && n >= 0) return { kind: "note", offset: n };
    }
    return { kind: "note", offset: 0 };
  }
  if (cursor.startsWith("r:")) {
    const rest = cursor.slice(2);
    if (/^\d+$/.test(rest)) {
      const n = Number(rest);
      if (Number.isSafeInteger(n) && n >= 0) return { kind: "refs", offset: n };
    }
    return { kind: "refs", offset: 0 };
  }
  if (/^\d+$/.test(cursor)) {
    const n = Number(cursor);
    if (Number.isSafeInteger(n) && n >= 0) return { kind: "refs", offset: n };
  }
  return { kind: "note", offset: 0 };
}

type StationListed = { address: string };

/// Aggregates workspace projects from SQLite `chat_listed` covering index (`CHAT_READS.projectSummary`)
/// merged with cached `PROJECTS.jsonl` metadata, paginated by bounded snapshot cursor within `PAGE_BYTE_BUDGET` (<= 32 KiB)
/// so live reorders during pagination produce zero duplicates and zero omissions.
export function projectsView(
  data: Data,
  stations: readonly StationListed[],
  scope: string,
  cursor?: string,
  collate?: HostCollate,
): { items: J[]; total: number; unclassifiedCount: number; crossCount: number; nextCursor?: string; staleCursor?: boolean } {
  let unclassifiedCount = 0;
  let crossCount = 0;
  const agg = new Map<string, { chatCount: number; runningCount: number; latestActiveAt: number }>();
  for (const s of stations) {
    if (!data.listed(s.address, "chats")) continue;
    for (const row of data.chatCounted(CHAT_READS.projectSummary, { station: s.address })) {
      const proj = row[0];
      const count = Number(row[1] ?? 0);
      const running = Number(row[2] ?? 0);
      const latest = Number(row[3] ?? 0);
      if (proj === null || proj === undefined) {
        unclassifiedCount += count;
      } else if (proj === "") {
        crossCount += count;
      } else if (typeof proj === "string") {
        const cur = agg.get(proj);
        if (cur === undefined) {
          agg.set(proj, { chatCount: count, runningCount: running, latestActiveAt: latest });
        } else {
          cur.chatCount += count;
          cur.runningCount += running;
          if (latest > cur.latestActiveAt) cur.latestActiveAt = latest;
        }
      }
    }
  }
  const infoMap = normalizeInfoMap(data.record("choice", projectsInfoKey(scope)));
  for (const name of Object.keys(infoMap)) {
    if (Object.hasOwn(infoMap, name) && !agg.has(name)) agg.set(name, { chatCount: 0, runningCount: 0, latestActiveAt: 0 });
  }
  const bucket = `projects:${scope}`;
  let snapId: string;
  let orderedNames: readonly string[];
  let startOffset: number;
  if (typeof cursor === "string" && cursor !== "") {
    const parsed = parseSnapCursor(cursor);
    const existingSnap = parsed !== null ? getPageSnapshot(data, bucket, parsed.snapId) : undefined;
    if (parsed === null || existingSnap === undefined) {
      return {
        items: [],
        total: agg.size,
        unclassifiedCount,
        crossCount,
        staleCursor: true,
      };
    }
    snapId = existingSnap.id;
    orderedNames = existingSnap.names;
    startOffset = Math.min(parsed.offset, orderedNames.length);
  } else {
    const allNames = [...agg.keys()];
    const cmp = makeCollator(allNames, collate);
    orderedNames = allNames.sort((a, b) => (agg.get(b)!.latestActiveAt - agg.get(a)!.latestActiveAt) || cmp(a, b));
    snapId = savePageSnapshot(data, bucket, orderedNames);
    startOffset = 0;
  }

  const items: J[] = [];
  const worstCursor = `s:${snapId}:${orderedNames.length}`;
  const envelopeBase = utf8Bytes({ items: [], total: agg.size, unclassifiedCount, crossCount, nextCursor: worstCursor });
  let used = envelopeBase;
  let idx = startOffset;
  while (idx < orderedNames.length) {
    const name = orderedNames[idx]!;
    const stats = agg.get(name);
    if (stats === undefined) {
      idx++;
      continue;
    }
    const meta = Object.hasOwn(infoMap, name) ? infoMap[name] : undefined;
    const hasInfo = meta !== undefined && (meta.note !== undefined || (meta.refs !== undefined && meta.refs.length > 0));
    let item: J = {
      name,
      chatCount: stats.chatCount,
      runningCount: stats.runningCount,
      latestActiveAt: stats.latestActiveAt,
      hasInfo,
    };
    let itemBytes = utf8Bytes(item) + 1;
    if (used + itemBytes > PAGE_BYTE_BUDGET) {
      if (items.length > 0) break;
      // Single item alone exceeds budget: safely truncate its name so 32 KiB cap is never broken.
      const avail = Math.max(MIN_ITEM_TEXT_BYTES, PAGE_BYTE_BUDGET - used - 96);
      item = { ...item, name: truncateJsonString(name, avail) };
      itemBytes = utf8Bytes(item) + 1;
    }
    items.push(item);
    used += itemBytes;
    idx++;
  }
  return {
    items,
    total: agg.size,
    unclassifiedCount,
    crossCount,
    ...(idx < orderedNames.length ? { nextCursor: `s:${snapId}:${idx}` } : {}),
  };
}

/// Detail view for a single project (`project` topic): merges cached `PROJECTS.jsonl` info with live SQLite counts,
/// paginating both `note` (<= 3.2 KiB per page so live note updates stay <= 4 KiB delta) and `refs` within 28 KiB.
export function projectDetailView(
  data: Data,
  stations: readonly StationListed[],
  scope: string,
  name: string,
  cursor?: string,
): { name: string; note?: string; refs: string[]; chatCount: number; runningCount: number; latestActiveAt: number; hasInfo: boolean; nextCursor?: string } {
  let chatCount = 0;
  let runningCount = 0;
  let latestActiveAt = 0;
  for (const s of stations) {
    if (!data.listed(s.address, "chats")) continue;
    for (const row of data.chatCounted(CHAT_READS.projectSummary, { station: s.address })) {
      if (row[0] !== name) continue;
      chatCount += Number(row[1] ?? 0);
      runningCount += Number(row[2] ?? 0);
      const latest = Number(row[3] ?? 0);
      if (latest > latestActiveAt) latestActiveAt = latest;
    }
  }
  const infoMap = normalizeInfoMap(data.record("choice", projectsInfoKey(scope)));
  const meta = Object.hasOwn(infoMap, name) ? infoMap[name] : undefined;
  const rawNote = meta?.note;
  const allRefs = meta?.refs ?? [];
  const hasInfo = rawNote !== undefined || allRefs.length > 0;

  const safeName = truncateJsonString(name, 512);
  const parsed = parseDetailCursor(cursor);

  let noteChunk: string | undefined;
  let refStart = 0;
  if (parsed.kind === "note") {
    if (rawNote !== undefined && parsed.offset < rawNote.length) {
      const sliced = sliceJsonString(rawNote, parsed.offset, DETAIL_NOTE_PAGE_BYTES);
      noteChunk = sliced.chunk;
      if (sliced.nextOffset < rawNote.length) {
        return {
          name: safeName,
          note: noteChunk,
          refs: [],
          chatCount,
          runningCount,
          latestActiveAt,
          hasInfo,
          nextCursor: `n:${sliced.nextOffset}`,
        };
      }
    }
    refStart = 0;
  } else {
    refStart = Math.min(parsed.offset, allRefs.length);
  }

  let used = utf8Bytes({
    name: safeName,
    ...(noteChunk !== undefined ? { note: noteChunk } : {}),
    refs: [],
    chatCount,
    runningCount,
    latestActiveAt,
    hasInfo,
    nextCursor: `r:${allRefs.length}`,
  });

  const refs: string[] = [];
  let idx = refStart;
  while (idx < allRefs.length) {
    let ref = allRefs[idx]!;
    let refBytes = utf8Bytes(ref) + 1;
    const isLoneRef = refs.length === 0 && noteChunk === undefined;
    const budget = isLoneRef ? DETAIL_SINGLE_REF_BUDGET : DETAIL_PAGE_BUDGET;
    if (used + refBytes > budget) {
      if (refs.length > 0 || noteChunk !== undefined) break;
      const avail = Math.max(MIN_ITEM_TEXT_BYTES, DETAIL_SINGLE_REF_BUDGET - used - 16);
      ref = truncateJsonString(ref, avail);
      refBytes = utf8Bytes(ref) + 1;
    }
    refs.push(ref);
    used += refBytes;
    idx++;
    if (used > DETAIL_PAGE_BUDGET) break;
  }

  return {
    name: safeName,
    ...(noteChunk !== undefined ? { note: noteChunk } : {}),
    refs,
    chatCount,
    runningCount,
    latestActiveAt,
    hasInfo,
    ...(idx < allRefs.length ? { nextCursor: `r:${idx}` } : {}),
  };
}

/// Aggregates workspace tags from `chat_tag_station` covering index (`CHAT_READS.tagSummary`),
/// sorted by `(chatCount DESC, name ASC)` via `collate`, paginated by bounded snapshot cursor within `PAGE_BYTE_BUDGET` (<= 32 KiB).
export function tagsView(
  data: Data,
  stations: readonly StationListed[],
  cursor?: string,
  collate?: HostCollate,
): { items: J[]; total: number; nextCursor?: string; staleCursor?: boolean } {
  const counts = new Map<string, number>();
  for (const s of stations) {
    if (!data.listed(s.address, "chats")) continue;
    for (const row of data.chatCounted(CHAT_READS.tagSummary, { station: s.address })) {
      const tag = row[0];
      const count = Number(row[1] ?? 0);
      if (typeof tag === "string" && tag !== "" && count > 0) {
        counts.set(tag, (counts.get(tag) ?? 0) + count);
      }
    }
  }
  const bucket = `tags:${stations.map((s) => s.address).sort().join(",")}`;
  let snapId: string;
  let orderedNames: readonly string[];
  let startOffset: number;
  if (typeof cursor === "string" && cursor !== "") {
    const parsed = parseSnapCursor(cursor);
    const existingSnap = parsed !== null ? getPageSnapshot(data, bucket, parsed.snapId) : undefined;
    if (parsed === null || existingSnap === undefined) {
      return {
        items: [],
        total: counts.size,
        staleCursor: true,
      };
    }
    snapId = existingSnap.id;
    orderedNames = existingSnap.names;
    startOffset = Math.min(parsed.offset, orderedNames.length);
  } else {
    const allNames = [...counts.keys()];
    const cmp = makeCollator(allNames, collate);
    orderedNames = allNames.sort((a, b) => (counts.get(b)! - counts.get(a)!) || cmp(a, b));
    snapId = savePageSnapshot(data, bucket, orderedNames);
    startOffset = 0;
  }

  const items: J[] = [];
  const worstCursor = `s:${snapId}:${orderedNames.length}`;
  let used = utf8Bytes({ items: [], total: counts.size, nextCursor: worstCursor });
  let idx = startOffset;
  while (idx < orderedNames.length) {
    const name = orderedNames[idx]!;
    const chatCount = counts.get(name);
    if (chatCount === undefined) {
      idx++;
      continue;
    }
    let item: J = { name, chatCount };
    let itemBytes = utf8Bytes(item) + 1;
    if (used + itemBytes > PAGE_BYTE_BUDGET) {
      if (items.length > 0) break;
      const avail = Math.max(MIN_ITEM_TEXT_BYTES, PAGE_BYTE_BUDGET - used - 64);
      item = { ...item, name: truncateJsonString(name, avail) };
      itemBytes = utf8Bytes(item) + 1;
    }
    items.push(item);
    used += itemBytes;
    idx++;
  }
  return {
    items,
    total: counts.size,
    ...(idx < orderedNames.length ? { nextCursor: `s:${snapId}:${idx}` } : {}),
  };
}

// ── network sync & operations ──

type WorkspaceInfoState = {
  gen: number;
  loadedStations: Set<string>;
  reqSeq: Map<string, number>;
  before: Set<string>;
  /// Per-station latest `GET /projects/info` snapshots (hydrated from & persisted to `projectsInfoByStationKey(ws)`):
  /// workspace cache is the `updatedAt`-merged union across stations, so an empty station never wipes another station's
  /// entries (including across restarts) while cross-device deletions converge once all stations drop the key.
  byStation: Map<string, CachedProjectsInfoMap>;
};
const infoStates = new WeakMap<Inner, Map<string, WorkspaceInfoState>>();
const LEGACY_SENTINEL = "__legacy__";

function infoStateOf(inner: Inner, ws: string): WorkspaceInfoState {
  let byWs = infoStates.get(inner);
  if (byWs === undefined) {
    byWs = new Map();
    infoStates.set(inner, byWs);
  }
  let st = byWs.get(ws);
  if (st === undefined) {
    const byStation = new Map<string, CachedProjectsInfoMap>();
    const saved = inner.data.record("choice", projectsInfoByStationKey(ws));
    if (isObject(saved)) {
      for (const addr of Object.keys(saved)) {
        if (Object.hasOwn(saved, addr)) byStation.set(addr, normalizeInfoMap(saved[addr]));
      }
    }
    if (byStation.size === 0) {
      const legacy = normalizeInfoMap(inner.data.record("choice", projectsInfoKey(ws)));
      if (Object.keys(legacy).length > 0) byStation.set(LEGACY_SENTINEL, legacy);
    }
    st = { gen: 0, loadedStations: new Set(), reqSeq: new Map(), before: new Set(), byStation };
    byWs.set(ws, st);
  }
  return st;
}

function serializeByStation(st: WorkspaceInfoState): Record<string, Record<string, CachedProjectInfo>> {
  const out: Record<string, Record<string, CachedProjectInfo>> = Object.create(null);
  for (const [addr, snap] of [...st.byStation.entries()].sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0))) {
    out[addr] = toPlainObject(snap);
  }
  return out;
}

function persistWorkspaceInfo(inner: Inner, ws: string, st: WorkspaceInfoState): void {
  const active = stationsOf(inner, ws).map((s) => s.address);
  if (active.length > 0) {
    const activeSet = new Set(active);
    for (const addr of [...st.byStation.keys()]) {
      if (addr !== LEGACY_SENTINEL && !activeSet.has(addr)) st.byStation.delete(addr);
    }
    if (
      st.byStation.has(LEGACY_SENTINEL) &&
      active.every((a) => st.loadedStations.has(a) || st.before.has(a) || stationProjectsEnabled(inner, a) === false)
    ) {
      st.byStation.delete(LEGACY_SENTINEL);
    }
  }
  const byStationObj = serializeByStation(st);
  const prevByStation = inner.data.record("choice", projectsInfoByStationKey(ws));
  if (JSON.stringify(byStationObj) !== JSON.stringify(prevByStation ?? null)) {
    inner.data.put("choice", projectsInfoByStationKey(ws), byStationObj, false);
  }
  const prev = normalizeInfoMap(inner.data.record("choice", projectsInfoKey(ws)));
  const merged = toPlainObject(rebuildWorkspaceInfo(st));
  const prevPlain = toPlainObject(prev);
  if (JSON.stringify(merged) !== JSON.stringify(prevPlain)) {
    inner.data.put("choice", projectsInfoKey(ws), merged, false);
  }
}

function rebuildWorkspaceInfo(st: WorkspaceInfoState): CachedProjectsInfoMap {
  let acc = emptyMap();
  for (const snap of st.byStation.values()) {
    acc = mergeProjectsInfoMaps(acc, snap);
  }
  return acc;
}

const ask = (inner: Inner, address: string, method: string, path: string, body: unknown = null) =>
  inner.stations.requests.call(inner.stations.link(address)?.addr ?? StationAddr.parse(address), method, path, body, { quiet: true });

const reached = (inner: Inner, address: string) =>
  inner.provider.kind === "stillfail" && inner.stations.link(address) !== undefined && inner.stations.reachable(address);

function overviewOf(inner: Inner, address: string): unknown {
  return inner.store.get({ topic: "overview", station: address }) ?? inner.data.overviewPart(address);
}

function stationProjectsEnabled(inner: Inner, address: string): boolean | null {
  const ov = overviewOf(inner, address);
  if (!isObject(ov)) return null;
  if (!Array.isArray(ov.features)) return null;
  return stationFeature(ov, "projects");
}

function stationsOf(inner: Inner, ws: string): { address: string; rig: boolean }[] {
  return arr(get(inner.data.shared({ topic: "workspace", workspace: ws }), "stations"))
    .map((s: J) => ({
      address: typeof get(s, "id") === "string" ? `${ws}/${s.id as string}` : "",
      rig: get(s, "mode") === "tasks" || get(s, "mode") === "rig",
    }))
    .filter((s) => s.address !== "");
}

function pickOnlineStations(inner: Inner, ws: string, preferred?: string): Effect.Effect<string[], CoreError> {
  const list = stationsOf(inner, ws);
  if (typeof preferred === "string" && preferred !== "") {
    if (ofAddress(preferred) !== ws || !list.some((s) => s.address === preferred) || !reached(inner, preferred)) {
      return Effect.fail(new CoreError("invalid_params", t("core-misc.projects.stationMismatch")));
    }
    return Effect.succeed([preferred]);
  }
  const online = list.filter((s) => reached(inner, s.address));
  if (online.length === 0) return Effect.fail(new CoreError("offline", t("core-misc.projects.noStation")));
  // Prefer non-rig/tasks stations that explicitly advertise `projects` feature.
  const score = (s: { address: string; rig: boolean }) => {
    const enabled = stationProjectsEnabled(inner, s.address);
    return (s.rig ? 0 : 4) + (enabled === true ? 2 : enabled === null ? 1 : 0);
  };
  online.sort((a, b) => score(b) - score(a));
  return Effect.succeed(online.map((s) => s.address));
}

function askWorkspace(
  inner: Inner,
  ws: string,
  preferred: string | undefined,
  method: string,
  path: string,
  body: unknown,
): Effect.Effect<{ station: string; res: unknown }, CoreError> {
  return Effect.gen(function* () {
    const candidates = yield* pickOnlineStations(inner, ws, preferred);
    let lastErr: CoreError | null = null;
    for (let i = 0; i < candidates.length; i++) {
      const station = candidates[i]!;
      const r = yield* Effect.result(ask(inner, station, method, path, body));
      if (r._tag === "Success") return { station, res: r.success };
      lastErr = r.failure;
      // Fall back to another full station when caller did not pin a station and the station lacks the route (404) or is a tasks/rig station (403).
      const isTasksRefusal = r.failure.status === 403 && /rig|tasks/i.test(r.failure.message);
      if (preferred === undefined && (fromBeforeRoute(r.failure) || isTasksRefusal) && i + 1 < candidates.length) continue;
      return yield* Effect.fail(r.failure);
    }
    return yield* Effect.fail(lastErr ?? new CoreError("offline", t("core-misc.projects.noStation")));
  });
}

/// Fetches `GET /projects/info` from `address` and merges into the workspace's cached info map in SQLite,
/// respecting feature gating, per-station monotonic request sequence, per-project `updatedAt` merging, and mutation generation.
export function fetchProjectsInfo(inner: Inner, address: string): Effect.Effect<void, CoreError> {
  return Effect.gen(function* () {
    if (!reached(inner, address)) return;
    const ws = ofAddress(address);
    const st = infoStateOf(inner, ws);
    const enabled = stationProjectsEnabled(inner, address);
    if (enabled === true) st.before.delete(address);
    if (enabled === false) {
      if (st.byStation.has(LEGACY_SENTINEL)) persistWorkspaceInfo(inner, ws, st);
      return;
    }
    const startGen = st.gen;
    const seq = (st.reqSeq.get(address) ?? 0) + 1;
    st.reqSeq.set(address, seq);
    const res = yield* Effect.result(ask(inner, address, "GET", "/projects/info"));
    if (res._tag === "Failure") {
      if (fromBeforeRoute(res.failure)) {
        st.before.add(address);
        if (st.byStation.has(LEGACY_SENTINEL)) persistWorkspaceInfo(inner, ws, st);
      }
      return;
    }
    // Discard stale GET if an authoritative write occurred or a newer GET for this same station was started while in flight.
    if (st.gen !== startGen || st.reqSeq.get(address) !== seq) return;
    st.loadedStations.add(address);
    const incoming = normalizeInfoMap(get(res.success, "projects"));
    st.byStation.set(address, incoming);
    persistWorkspaceInfo(inner, ws, st);
  });
}

type ProjectsCall = Extract<Call, { kind: "projects" }>;

export function install(inner: Inner): void {
  inner.stations.also.push({
    read: (address) => Effect.ignore(fetchProjectsInfo(inner, address)),
    event: (address, name, data) => {
      const ws = ofAddress(address);
      if ((name === "projects" || name === "projectsInfo") && (get(data, "workspace") === undefined || get(data, "workspace") === ws)) {
        inner.scheduler.enqueue(address, `projectsInfo/${address}`, Priority.background, Effect.ignore(fetchProjectsInfo(inner, address)));
      }
    },
    resumed: (address) =>
      Effect.suspend(() => {
        const ws = ofAddress(address);
        const st = infoStateOf(inner, ws);
        if (stationProjectsEnabled(inner, address) === true) st.before.delete(address);
        if (st.loadedStations.has(address) || st.before.has(address)) return Effect.void;
        return Effect.ignore(fetchProjectsInfo(inner, address));
      }),
  });

  handlers.projects = (core, call) => {
    const c = call as ProjectsCall;
    const p = c.params;
    return Effect.gen(function* () {
      switch (c.name) {
        case "classify": {
          const station = str(p.station);
          const thread = typeof p.thread === "number" ? p.thread : null;
          if (station === null || thread === null) return yield* Effect.fail(CoreError.invalid(t("core-misc.projects.invalidParams")));
          const body: Record<string, unknown> = {};
          const overlay: Record<string, unknown> = { projectLocked: true };
          if ("project" in p && p.project !== undefined) {
            body.project = p.project;
            overlay.project = p.project;
          }
          if ("tags" in p && p.tags !== undefined) {
            body.tags = p.tags;
            overlay.tags = p.tags;
          }
          const changeId = core.views.local.changing(station, thread, "", overlay, null);
          const out = yield* Effect.result(ask(core, station, "PUT", `/threads/${thread}/classification`, body));
          if (out._tag === "Failure") {
            core.views.local.changed(changeId, false, core.data.rowsRev(station));
            return yield* Effect.fail(out.failure);
          }
          core.views.local.changed(changeId, true, core.data.rowsRev(station));
          // Refresh PROJECTS.jsonl cache if a non-empty project was assigned (station auto-registers it).
          if (typeof body.project === "string" && body.project !== "") {
            core.scheduler.enqueue(station, `projectsInfo/${station}`, Priority.background, Effect.ignore(fetchProjectsInfo(core, station)));
          }
          return out.success;
        }
        case "resolveProposal": {
          const station = str(p.station);
          const thread = typeof p.thread === "number" ? p.thread : null;
          const entryN = typeof p.entryN === "number" ? p.entryN : null;
          const action = str(p.action);
          if (station === null || thread === null || entryN === null || action === null) {
            return yield* Effect.fail(CoreError.invalid(t("core-misc.projects.invalidParams")));
          }
          const body: Record<string, unknown> = { action };
          if (typeof p.name === "string") body.name = p.name;
          if (typeof p.target === "string") body.target = p.target;
          if ("note" in p && p.note !== undefined) body.note = p.note;
          if ("refs" in p && p.refs !== undefined) body.refs = p.refs;
          if (p.markCross === true) body.markCross = true;
          const res = yield* ask(core, station, "POST", `/threads/${thread}/proposals/${entryN}/resolve`, body);
          if (action === "accept" || action === "reassign") {
            core.scheduler.enqueue(station, `projectsInfo/${station}`, Priority.background, Effect.ignore(fetchProjectsInfo(core, station)));
          }
          return res;
        }
        case "updateInfo": {
          const ws = c.scope;
          const name = str(p.name);
          if (name === null) return yield* Effect.fail(CoreError.invalid(t("core-misc.projects.invalidParams")));
          const body: Record<string, unknown> = { name };
          if ("note" in p && p.note !== undefined) body.note = p.note;
          if ("refs" in p && p.refs !== undefined) body.refs = p.refs;
          if (p.delete === true) body.delete = true;
          const { station, res } = yield* askWorkspace(core, ws, str(p.station) ?? undefined, "PUT", "/projects/info", body);
          const st = infoStateOf(core, ws);
          st.gen++;
          st.loadedStations.add(station);
          const incoming = normalizeInfoMap(get(res, "projects"));
          st.byStation.set(station, incoming);
          for (const snap of st.byStation.values()) {
            if (body.delete === true) delete snap[name];
            else if (Object.hasOwn(incoming, name)) snap[name] = incoming[name]!;
          }
          persistWorkspaceInfo(core, ws, st);
          return res;
        }
        case "rename":
        case "merge": {
          const ws = c.scope;
          const from = typeof p.from === "string" ? p.from : null;
          const to = typeof p.to === "string" ? p.to : null;
          if (from === null || to === null) return yield* Effect.fail(CoreError.invalid(t("core-misc.projects.invalidParams")));
          const { station, res } = yield* askWorkspace(core, ws, str(p.station) ?? undefined, "POST", `/projects/${c.name}`, { from, to });
          const st = infoStateOf(core, ws);
          st.gen++;
          if (st.byStation.size > 0) {
            for (const snap of st.byStation.values()) {
              if (Object.hasOwn(snap, from)) {
                const moved = snap[from]!;
                delete snap[from];
                if (to !== "" && !Object.hasOwn(snap, to)) snap[to] = moved;
              }
            }
            persistWorkspaceInfo(core, ws, st);
          } else {
            const prev = normalizeInfoMap(core.data.record("choice", projectsInfoKey(ws)));
            if (Object.hasOwn(prev, from)) {
              const moved = prev[from]!;
              delete prev[from];
              if (to !== "" && !Object.hasOwn(prev, to)) prev[to] = moved;
              core.data.put("choice", projectsInfoKey(ws), toPlainObject(prev), false);
            }
          }
          core.scheduler.enqueue(station, `projectsInfo/${station}`, Priority.background, Effect.ignore(fetchProjectsInfo(core, station)));
          return res;
        }
      }
    });
  };
}
