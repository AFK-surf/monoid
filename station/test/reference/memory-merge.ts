// The TypeScript the station merged the agents' memory with before it moved to the MoonBit program (station/mb
// src/memory, reader `--builder memory`: station/src/share/memory-mb.ts), kept for the tests to compare the program
// with (test/mb-memory-merge.test.ts): this file's functions as share/memory-merge.ts had them, and what of
// share/memory.ts moved with them (`decide`, the files read by `#read`, as `readMemory`).
//
// Two versions of one file of the agents' memory made apart, put together (share/memory.ts): what each station of a
// workspace computes alike from the same two versions, so they come to one without a station to decide.
//
// - With the version both were made from (`base`): a three-way merge by lines, as `git merge-file` makes one, where a
//   place both changed keeps both, the newer's lines first (git's `union`): a line a station's agent added is never
//   lost, and an agent that reads the file tidies what came twice.
// - Without one (two stations that kept the memory apart before it was shared): MEMORY.md's lines both, each once, a
//   line only one of them had marked with that station's name (`[ccvm] `), since nothing tells whether it is of that
//   machine alone; another file is the newer's, the other kept beside it (`conflictPath`) for an agent to merge.

import { createHash } from "node:crypto";
import type { Dirent } from "node:fs";
import { lstat, readdir, readFile } from "node:fs/promises";
import { join } from "node:path";
import { portableName } from "../../src/ops/paths.ts";
import { BUILTIN_SKILLS, FEEDBACK_SKILL, RETIRED_SKILLS } from "../../src/sessions/agent-home.ts";
import { memoryPath, type Rec, SKIPPED } from "../../src/share/memory.ts";

/// The most lines a side of a merge may have past what the two share at their start and end: beyond it no merge is
/// tried (the newer is kept and the other beside it).
const MOST_LINES = 3000;

/// Whether `bytes` are text a merge by lines may read: UTF-8 with no NUL.
export function isText(bytes: Buffer): boolean {
  if (bytes.includes(0)) return false;
  return Buffer.from(bytes.toString("utf8"), "utf8").equals(bytes);
}

/// The pairs of lines `a` and `b` have alike (indexes, both rising), a longest such sequence; null when the lines that
/// differ are too many to compare.
export function matches(a: string[], b: string[]): [number, number][] | null {
  let start = 0;
  while (start < a.length && start < b.length && a[start] === b[start]) start++;
  let endA = a.length;
  let endB = b.length;
  while (endA > start && endB > start && a[endA - 1] === b[endB - 1]) endA--, endB--;
  const n = endA - start;
  const m = endB - start;
  if (n > MOST_LINES || m > MOST_LINES) return null;
  const out: [number, number][] = [];
  for (let i = 0; i < start; i++) out.push([i, i]);
  if (n > 0 && m > 0) {
    // lcs[i][j]: the longest of a[start+i..endA) and b[start+j..endB).
    const width = m + 1;
    const lcs = new Uint16Array((n + 1) * width);
    for (let i = n - 1; i >= 0; i--) {
      for (let j = m - 1; j >= 0; j--) {
        lcs[i * width + j] = a[start + i] === b[start + j] ? lcs[(i + 1) * width + j + 1]! + 1 : Math.max(lcs[(i + 1) * width + j]!, lcs[i * width + j + 1]!);
      }
    }
    let i = 0;
    let j = 0;
    while (i < n && j < m) {
      if (a[start + i] === b[start + j]) {
        out.push([start + i, start + j]);
        i++, j++;
      } else if (lcs[(i + 1) * width + j]! >= lcs[i * width + j + 1]!) i++;
      else j++;
    }
  }
  for (let k = 0; endA + k < a.length; k++) out.push([endA + k, endB + k]);
  return out;
}

const sameSlice = (xs: string[], a: number, ea: number, ys: string[], b: number, eb: number) => {
  if (ea - a !== eb - b) return false;
  for (let k = 0; a + k < ea; k++) if (xs[a + k] !== ys[b + k]) return false;
  return true;
};

/// Marks every line that opens, closes, or lies inside a CommonMark fenced code block (0-3 leading spaces + >= 3
/// repeated '`' or '~'; backtick opening fences forbid '`' in the info string; closing fences require matching char,
/// length >= opening, and only spaces/tabs/optional CR after).
function fenceFlags(lines: string[]): boolean[] {
  const flags: boolean[] = [];
  let inFence = false;
  let fenceChar = 0;
  let fenceLen = 0;
  for (const line of lines) {
    const n = line.length;
    let sp = 0;
    while (sp < n && line.charCodeAt(sp) === 32) sp++;
    if (!inFence) {
      if (sp <= 3 && sp + 3 <= n && (line.charCodeAt(sp) === 96 || line.charCodeAt(sp) === 126)) {
        const ch = line.charCodeAt(sp);
        let run = 0;
        while (sp + run < n && line.charCodeAt(sp + run) === ch) run++;
        if (run >= 3) {
          let ok = true;
          if (ch === 96) {
            let end = n;
            if (end > sp + run && line.charCodeAt(end - 1) === 13) end--;
            for (let k = sp + run; k < end; k++) {
              if (line.charCodeAt(k) === 96) {
                ok = false;
                break;
              }
            }
          }
          if (ok) {
            inFence = true;
            fenceChar = ch;
            fenceLen = run;
            flags.push(true);
            continue;
          }
        }
      }
      flags.push(false);
    } else {
      flags.push(true);
      if (sp <= 3 && sp + fenceLen <= n && line.charCodeAt(sp) === fenceChar) {
        let run = 0;
        while (sp + run < n && line.charCodeAt(sp + run) === fenceChar) run++;
        if (run >= fenceLen) {
          let end = n;
          if (end > sp + run && line.charCodeAt(end - 1) === 13) end--;
          let onlyWs = true;
          for (let k = sp + run; k < end; k++) {
            const c = line.charCodeAt(k);
            if (c !== 32 && c !== 9) {
              onlyWs = false;
              break;
            }
          }
          if (onlyWs) inFence = false;
        }
      }
    }
  }
  return flags;
}

type Hunk = { bs: number; be: number; ss: number; se: number };

function extractHunks(bLen: number, sLen: number, pairs: [number, number][]): Hunk[] {
  const hunks: Hunk[] = [];
  let pb = 0;
  let ps = 0;
  for (const [bi, si] of pairs) {
    if (pb < bi || ps < si) hunks.push({ bs: pb, be: bi, ss: ps, se: si });
    pb = bi + 1;
    ps = si + 1;
  }
  if (pb < bLen || ps < sLen) hunks.push({ bs: pb, be: bLen, ss: ps, se: sLen });
  return hunks;
}

function hunksOverlap(aBs: number, aBe: number, bBs: number, bBe: number): boolean {
  if (aBs === aBe && bBs === bBe) return aBs === bBs;
  return aBs < bBe && bBs < aBe;
}

/// `newer` and `older` made from `base`, merged by lines using lossless hunk-based diff3: non-overlapping edits
/// (including adjacent edits) merge cleanly without reviving deleted lines; overlapping conflicts keep both sides
/// (newer first, once if identical) without dropping any lines. Null when too far apart to compare.
export function merge3(base: string, newer: string, older: string): string | null {
  const b = base.split("\n");
  const w = newer.split("\n");
  const l = older.split("\n");
  const bw = matches(b, w);
  const bl = matches(b, l);
  if (bw === null || bl === null) return null;
  const wh = extractHunks(b.length, w.length, bw);
  const lh = extractHunks(b.length, l.length, bl);
  const out: string[] = [];
  const push = (xs: string[], from: number, to: number) => {
    for (let k = from; k < to; k++) out.push(xs[k]!);
  };
  let wi = 0;
  let li = 0;
  let pos = 0;
  while (wi < wh.length || li < lh.length) {
    if (li >= lh.length) {
      const h = wh[wi]!;
      push(b, pos, h.bs);
      push(w, h.ss, h.se);
      pos = h.be;
      wi++;
    } else if (wi >= wh.length) {
      const h = lh[li]!;
      push(b, pos, h.bs);
      push(l, h.ss, h.se);
      pos = h.be;
      li++;
    } else {
      const hw = wh[wi]!;
      const hl = lh[li]!;
      if (!hunksOverlap(hw.bs, hw.be, hl.bs, hl.be)) {
        if (hw.be <= hl.bs) {
          push(b, pos, hw.bs);
          push(w, hw.ss, hw.se);
          pos = hw.be;
          wi++;
        } else {
          push(b, pos, hl.bs);
          push(l, hl.ss, hl.se);
          pos = hl.be;
          li++;
        }
      } else {
        const wiStart = wi;
        const liStart = li;
        const bsMin = Math.min(hw.bs, hl.bs);
        let beMax = Math.max(hw.be, hl.be);
        wi++;
        li++;
        let changed = true;
        while (changed) {
          changed = false;
          if (wi < wh.length && hunksOverlap(wh[wi]!.bs, wh[wi]!.be, bsMin, beMax)) {
            if (wh[wi]!.be > beMax) beMax = wh[wi]!.be;
            wi++;
            changed = true;
          }
          if (li < lh.length && hunksOverlap(lh[li]!.bs, lh[li]!.be, bsMin, beMax)) {
            if (lh[li]!.be > beMax) beMax = lh[li]!.be;
            li++;
            changed = true;
          }
        }
        push(b, pos, bsMin);
        const fw = wh[wiStart]!;
        const lw = wh[wi - 1]!;
        const wLo = fw.ss - (fw.bs - bsMin);
        const wHi = lw.se + (beMax - lw.be);
        const fl = lh[liStart]!;
        const ll = lh[li - 1]!;
        const lLo = fl.ss - (fl.bs - bsMin);
        const lHi = ll.se + (beMax - ll.be);
        if (sameSlice(w, wLo, wHi, l, lLo, lHi)) {
          push(w, wLo, wHi);
        } else {
          push(w, wLo, wHi);
          push(l, lLo, lHi);
        }
        pos = beMax;
      }
    }
  }
  push(b, pos, b.length);
  return out.join("\n");
}

/// A bullet's or a line's mark of the station it came from, as `marked` writes it: `- [ccvm] …` (excluding task checkboxes `[ ] `, `[x] `, `[X] `).
const MARK = /^(\s*(?:[-*+]|\d+\.)\s+|)\[(?![ xX]\])[^\]\n]{1,80}\] /;
const unmarked = (line: string) => line.replace(MARK, "$1");
/// A line worth marking: one that says something (not blank, not a heading, not the front matter's fence).
const says = (line: string) => line.trim() !== "" && !line.trimStart().startsWith("#") && line.trim() !== "---";
const marked = (line: string, station: string) => {
  if (!says(line) || unmarked(line) !== line) return line;
  const lead = /^(\s*(?:[-*+]|\d+\.)\s+|)/.exec(line)![0];
  return `${lead}[${station}] ${line.slice(lead.length)}`;
};

/// Two files kept apart (no version both were made from) as one: lossless across all file types (fenced lines
/// untouched; shared non-fence lines on `newer` unmarked even when reordered; `MEMORY.md` deduplication runs in
/// `decide` via `dedupMemoryLines`).
export function unionLines(newer: string, older: string, newerName: string | null, olderName: string | null): string {
  const w = newer.split("\n");
  const l = older.split("\n");
  const wu = w.map(unmarked);
  const lu = l.map(unmarked);
  const inFenceW = fenceFlags(w);
  const inFenceL = fenceFlags(l);
  const lKeys = new Set<string>();
  for (let j = 0; j < l.length; j++) {
    if (!inFenceL[j] && says(lu[j]!)) lKeys.add(lu[j]!.trim());
  }
  const pairs = matches(wu, lu) ?? [];
  const out: string[] = [];
  let [pw, pl] = [0, 0];
  const take = (ew: number, el: number) => {
    for (let k = pw; k < ew; k++) {
      if (inFenceW[k]) out.push(w[k]!);
      else if (says(wu[k]!) && lKeys.has(wu[k]!.trim())) out.push(wu[k]!);
      else out.push(newerName === null ? w[k]! : marked(w[k]!, newerName));
    }
    for (let k = pl; k < el; k++) {
      if (inFenceL[k]) out.push(l[k]!);
      else if (pairs.length === 0 && w.length > 0 && lu[k]!.trim() === "") {
        const isTrailingNl = k === l.length - 1 && l[k] === "";
        if (isTrailingNl || out.length === 0 || out[out.length - 1]!.trim() !== "") out.push(l[k]!);
      } else {
        out.push(olderName === null ? l[k]! : marked(l[k]!, olderName));
      }
    }
  };
  for (const [iw, il] of pairs) {
    take(iw, il);
    // Had by both: no station's alone, so unmarked unless inside a code fence.
    out.push(inFenceW[iw] ? w[iw]! : wu[iw]!);
    [pw, pl] = [iw + 1, il + 1];
  }
  take(w.length, l.length);
  return out.join("\n");
}

function isThematicBreak(line: string): boolean {
  const t = line.trim();
  if (t.length < 3) return false;
  const ch = t.charCodeAt(0);
  if (ch !== 45 && ch !== 42 && ch !== 95) return false;
  let count = 0;
  for (let i = 0; i < t.length; i++) {
    const c = t.charCodeAt(i);
    if (c === ch) count++;
    else if (c !== 32 && c !== 9) return false;
  }
  return count >= 3;
}

function isTableLine(u: string): boolean {
  const t = u.trim();
  if (t.length === 0) return false;
  if (t.charCodeAt(0) === 124) return true;
  let hasPipe = false;
  for (let i = 0; i < t.length; i++) {
    const c = t.charCodeAt(i);
    if (c === 124) hasPipe = true;
    else if (c !== 45 && c !== 58 && c !== 32 && c !== 9) return false;
  }
  return hasPipe;
}

function isHtmlLine(line: string): boolean {
  const t = line.trimStart();
  return t.length > 0 && t.charCodeAt(0) === 60;
}

function isIndentedCode(line: string): boolean {
  if (line.trim() === "" || /^(\s*(?:[-*+]|\d+\.)\s+)/.test(line)) return false;
  if (line.length === 0) return false;
  if (line.charCodeAt(0) === 9) return true;
  return line.length >= 4 && line.charCodeAt(0) === 32 && line.charCodeAt(1) === 32 && line.charCodeAt(2) === 32 && line.charCodeAt(3) === 32;
}

function headingOf(line: string): [number, string] | null {
  const t = line.trim();
  const n = t.length;
  if (n === 0 || t.charCodeAt(0) !== 35) return null;
  let level = 0;
  while (level < n && level < 7 && t.charCodeAt(level) === 35) level++;
  if (level < 1 || level > 6) return null;
  if (level === n) return [level, t];
  const next = t.charCodeAt(level);
  if (next === 32 || next === 9) return [level, t];
  return null;
}

function pushHeading(stack: [number, string][], level: number, ht: string): void {
  while (stack.length > 0 && stack[stack.length - 1]![0] >= level) stack.pop();
  stack.push([level, ht]);
}

function scopePath(stack: [number, string][]): string {
  return stack.map((x) => x[1]).join("\n");
}

/// Deterministic exact-line deduplication for merged `MEMORY.md` content.
export function dedupMemoryLines(text: string): string {
  const hadTrailingNl = text.length > 0 && text.charCodeAt(text.length - 1) === 10;
  const lines = text.split("\n");
  const bodyLen = hadTrailingNl ? lines.length - 1 : lines.length;
  const inFence = fenceFlags(lines);
  const hasUnmarked = new Set<string>();
  const stack1: [number, string][] = [];
  for (let i = 0; i < bodyLen; i++) {
    if (inFence[i] || isIndentedCode(lines[i]!) || isHtmlLine(lines[i]!) || isThematicBreak(lines[i]!)) continue;
    const h = headingOf(lines[i]!);
    if (h !== null) {
      pushHeading(stack1, h[0], h[1]);
      continue;
    }
    const u = unmarked(lines[i]!);
    if (isTableLine(u)) continue;
    if (says(u) && u === lines[i]) hasUnmarked.add(`${scopePath(stack1)}\n${u.trim()}`);
  }
  const seenContent = new Set<string>();
  const seenHeadingPaths = new Set<string>();
  const headingStack: [number, string][] = [];
  const out: string[] = [];
  let droppedSinceLastKept = false;
  for (let i = 0; i < bodyLen; i++) {
    if (inFence[i] || isIndentedCode(lines[i]!) || isHtmlLine(lines[i]!) || isThematicBreak(lines[i]!)) {
      out.push(lines[i]!);
      droppedSinceLastKept = false;
      continue;
    }
    const h = headingOf(lines[i]!);
    if (h !== null) {
      const [lvl, ht] = h;
      pushHeading(headingStack, lvl, ht);
      const path = scopePath(headingStack);
      if (seenHeadingPaths.has(path)) {
        const simStack: [number, string][] = [...headingStack];
        let hasNew = false;
        for (let j = i + 1; j < bodyLen; j++) {
          if (inFence[j] || isIndentedCode(lines[j]!) || isHtmlLine(lines[j]!)) {
            hasNew = true;
            break;
          }
          if (isThematicBreak(lines[j]!)) continue;
          const hj = headingOf(lines[j]!);
          if (hj !== null) {
            if (hj[0] <= lvl) break;
            pushHeading(simStack, hj[0], hj[1]);
            continue;
          }
          const uj = unmarked(lines[j]!);
          if (isTableLine(uj)) {
            hasNew = true;
            break;
          }
          if (says(uj) && !seenContent.has(`${scopePath(simStack)}\n${uj.trim()}`)) {
            hasNew = true;
            break;
          }
        }
        if (!hasNew) {
          droppedSinceLastKept = true;
          continue;
        }
      }
      seenHeadingPaths.add(path);
      out.push(lines[i]!);
      droppedSinceLastKept = false;
      continue;
    }
    const u = unmarked(lines[i]!);
    if (isTableLine(u)) {
      out.push(lines[i]!);
      droppedSinceLastKept = false;
      continue;
    }
    if (says(u)) {
      const scopedKey = `${scopePath(headingStack)}\n${u.trim()}`;
      if (seenContent.has(scopedKey)) {
        droppedSinceLastKept = true;
      } else {
        seenContent.add(scopedKey);
        out.push(hasUnmarked.has(scopedKey) ? u : lines[i]!);
        droppedSinceLastKept = false;
      }
      continue;
    }
    if (lines[i]!.trim() === "") {
      if (droppedSinceLastKept && (out.length === 0 || out[out.length - 1]!.trim() === "")) continue;
      out.push(lines[i]!);
    } else {
      out.push(lines[i]!);
      droppedSinceLastKept = false;
    }
  }
  if (droppedSinceLastKept) {
    while (out.length > 0 && out[out.length - 1]!.trim() === "") out.pop();
  }
  return hadTrailingNl ? `${out.join("\n")}\n` : out.join("\n");
}

/// Where a station's version of `path` is kept beside it when it could not be merged: `SKILL.md` →
/// `SKILL.conflict-<station>.md` (as the shared skills keep one, share/index.ts).
export function conflictPath(path: string, station: string): string {
  const slash = path.lastIndexOf("/");
  const dir = path.slice(0, slash + 1);
  const name = path.slice(slash + 1);
  const dot = name.lastIndexOf(".");
  const tag = stationTag(station);
  return dot > 0 ? `${dir}${name.slice(0, dot)}.conflict-${tag}${name.slice(dot)}` : `${dir}${name}.conflict-${tag}`;
}

/// A station's name as a part of a file's or a skill's name: letters, digits, `_` and `-` alone.
export const stationTag = (station: string): string => station.replace(/[^\p{L}\p{N}_-]+/gu, "-").replace(/^-+|-+$/g, "").slice(0, 40) || "station";

/// Whether two versions made apart with none both came from are of one file still (a skill two stations each kept on):
/// half the lines of the shorter, at least, the other has too, in order, past their front matter (which every skill's
/// starts alike).
export function alike(a: string, b: string): boolean {
  const body = (t: string) => t.replace(/^---\n[\s\S]*?\n---\n?/, "");
  const la = body(a).split("\n");
  const lb = body(b).split("\n");
  const pairs = matches(la, lb);
  if (pairs === null) return false;
  const said = pairs.filter(([i]) => la[i]!.trim() !== "").length;
  const least = Math.min(la.filter((l) => l.trim() !== "").length, lb.filter((l) => l.trim() !== "").length);
  return least > 0 && said * 2 >= least;
}

// ── share/memory.ts's, as it was ──

const FILE_MOST = 512 * 1024;
const SKILL_MOST = 4 * 1024 * 1024;
const SKILL_FILES = 200;
const PREV_MOST = 16;
const BUILTIN = new Set([...BUILTIN_SKILLS, FEEDBACK_SKILL, ...RETIRED_SKILLS]);
const sha = (bytes: Buffer) => createHash("sha256").update(bytes).digest("hex");
const modeOf = (m: number) => ((m & 0o100) !== 0 ? 0o755 : 0o644);
const own = (m: number) => (m & 0o077) === 0;

/// Which of two records is the newer: the later, then the station of the greater id, then the greater hash.
const newer = (a: Rec, b: Rec) => (a.at !== b.at ? a.at > b.at : a.by !== b.by ? a.by > b.by : a.hash > b.hash);
const history = (r: Rec) => [r.hash, ...r.prev].filter((h) => h !== "");

export type Outcome = { kind: "keep" } | { kind: "take"; rec: Rec } | { kind: "merge"; rec: Rec; content: Buffer | null; beside: { path: string; rec: Rec; content: Buffer } | null };

export function compactProjectsJsonl(text: string): string {
  const maxDel = new Map<string, number>();
  const parsedLive: {
    name: string;
    at: number;
    hasAt: boolean;
    note: string;
    noteAt: number;
    hasNoteAt: boolean;
    refsWithAt: [string, number][];
    hasRefsAt: boolean;
    noteClearedAt?: number;
    refsClearedAt?: number;
  }[] = [];
  const extra: string[] = [];
  // Pass 1: parse lines and collect max deletion watermarks.
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (line === "") continue;
    try {
      const obj = JSON.parse(line);
      if (obj && typeof obj === "object" && !Array.isArray(obj) && typeof obj.name === "string" && obj.name !== "") {
        const hasAt = typeof obj.updatedAt === "number" && Number.isFinite(obj.updatedAt);
        const at = hasAt ? obj.updatedAt : -1;
        if (obj.deleted === true) {
          const delAt = hasAt ? at : 0;
          const prev = maxDel.get(obj.name);
          if (prev === undefined || delAt > prev) maxDel.set(obj.name, delAt);
          continue;
        }
        if (typeof obj.deletedAt === "number" && Number.isFinite(obj.deletedAt)) {
          const prev = maxDel.get(obj.name);
          if (prev === undefined || obj.deletedAt > prev) maxDel.set(obj.name, obj.deletedAt);
        }
        const hasOwnNoteAt = typeof obj.noteAt === "number" && Number.isFinite(obj.noteAt);
        const noteAt = hasOwnNoteAt ? obj.noteAt : at;
        const hasNoteAt = hasOwnNoteAt || hasAt;
        const hasOwnRefsFallback = typeof obj.refsAt === "number" && Number.isFinite(obj.refsAt);
        const refsFallback = hasOwnRefsFallback ? obj.refsAt : at;
        const hasRefsFallback = hasOwnRefsFallback || hasAt;
        const noteClearedAt = typeof obj.noteClearedAt === "number" && Number.isFinite(obj.noteClearedAt) ? obj.noteClearedAt : undefined;
        const refsClearedAt = typeof obj.refsClearedAt === "number" && Number.isFinite(obj.refsClearedAt) ? obj.refsClearedAt : undefined;
        const note = typeof obj.note === "string" ? obj.note : "";
        const rawRefAts = obj.refAts && typeof obj.refAts === "object" && !Array.isArray(obj.refAts)
          ? (obj.refAts as Record<string, unknown>)
          : null;
        const refsWithAt: [string, number][] = [];
        const seenRefs = new Set<string>();
        let hasRefsAt = false;
        if (Array.isArray(obj.refs)) {
          for (const x of obj.refs) {
            if (typeof x === "string" && x !== "" && !seenRefs.has(x)) {
              seenRefs.add(x);
              const rawV = rawRefAts !== null && Object.prototype.hasOwnProperty.call(rawRefAts, x) ? rawRefAts[x] : undefined;
              const own = typeof rawV === "number" && Number.isFinite(rawV) ? rawV : undefined;
              if (own !== undefined || hasRefsFallback) hasRefsAt = true;
              refsWithAt.push([x, own !== undefined ? own : refsFallback]);
            }
          }
        }
        parsedLive.push({ name: obj.name, at, hasAt, note, noteAt, hasNoteAt, refsWithAt, hasRefsAt, noteClearedAt, refsClearedAt });
        continue;
      }
    } catch {}
    extra.push(line);
  }
  // Filter surviving live rows (at > maxDel) and collect field-level clear watermarks.
  const surviving: typeof parsedLive = [];
  const maxNoteCleared = new Map<string, number>();
  const maxRefsCleared = new Map<string, number>();
  for (const item of parsedLive) {
    const delAt = maxDel.get(item.name);
    if (delAt !== undefined && item.at <= delAt) continue;
    surviving.push(item);
    if (item.noteClearedAt !== undefined) {
      const prev = maxNoteCleared.get(item.name);
      if (prev === undefined || item.noteClearedAt > prev) maxNoteCleared.set(item.name, item.noteClearedAt);
    }
    if (item.refsClearedAt !== undefined) {
      const prev = maxRefsCleared.get(item.name);
      if (prev === undefined || item.refsClearedAt > prev) maxRefsCleared.set(item.name, item.refsClearedAt);
    }
  }
  // Pass 2: filter cleared fields by max(clear watermark, project deletion watermark) & per-ref `refAts`, and merge associatively.
  const byName = new Map<string, { at: number; hasAt: boolean; note: string; noteAt: number; hasNoteAt: boolean; refAts: Map<string, number>; hasRefsAt: boolean }>();
  for (const item of surviving) {
    const delCut = maxDel.get(item.name);
    const nc = maxNoteCleared.get(item.name);
    const rc = maxRefsCleared.get(item.name);
    const noteCut = nc !== undefined && delCut !== undefined ? Math.max(nc, delCut) : (nc ?? delCut);
    const refsCut = rc !== undefined && delCut !== undefined ? Math.max(rc, delCut) : (rc ?? delCut);
    const keepNote = item.note !== "" && (noteCut === undefined || item.noteAt > noteCut);
    const note = keepNote ? item.note : "";
    const noteAt = keepNote ? item.noteAt : -1;
    const hasNoteAt = keepNote && item.hasNoteAt;
    const rowRefAts = new Map<string, number>();
    let rowHasRefsAt = false;
    for (const [r, rAt] of item.refsWithAt) {
      if (refsCut !== undefined && rAt <= refsCut) continue;
      const prevRa = rowRefAts.get(r);
      if (prevRa === undefined || rAt > prevRa) rowRefAts.set(r, rAt);
      if (item.hasRefsAt) rowHasRefsAt = true;
    }
    const prev = byName.get(item.name);
    if (!prev) {
      byName.set(item.name, { at: item.at, hasAt: item.hasAt, note, noteAt, hasNoteAt, refAts: rowRefAts, hasRefsAt: rowHasRefsAt });
    } else {
      let mergedNote = prev.note;
      let mergedNoteAt = prev.noteAt;
      let mergedHasNoteAt = prev.hasNoteAt;
      if (note !== "" && prev.note !== "") {
        const inWins = noteAt !== prev.noteAt ? noteAt > prev.noteAt : note > prev.note;
        if (inWins) {
          mergedNote = note;
          mergedNoteAt = noteAt;
          mergedHasNoteAt = hasNoteAt;
        }
      } else if (note !== "") {
        mergedNote = note;
        mergedNoteAt = noteAt;
        mergedHasNoteAt = hasNoteAt;
      }
      for (const [r, rAt] of rowRefAts) {
        const oldRa = prev.refAts.get(r);
        if (oldRa === undefined || rAt > oldRa) prev.refAts.set(r, rAt);
      }
      byName.set(item.name, {
        at: Math.max(item.at, prev.at),
        hasAt: item.hasAt || prev.hasAt,
        note: mergedNote,
        noteAt: mergedNoteAt,
        hasNoteAt: mergedHasNoteAt,
        refAts: prev.refAts,
        hasRefsAt: rowHasRefsAt || prev.hasRefsAt,
      });
    }
  }
  const allNames = [...new Set([...byName.keys(), ...maxDel.keys()])].sort();
  const out: string[] = [];
  for (const name of allNames) {
    const e = byName.get(name);
    const delAt = maxDel.get(name);
    if (e) {
      const rec: Record<string, unknown> = { name };
      if (e.note !== "") {
        rec.note = e.note;
        if (e.hasNoteAt) rec.noteAt = e.noteAt;
      }
      const sortedRefs = [...e.refAts.keys()].sort((a, b) => {
        const da = e.refAts.get(a)!;
        const db = e.refAts.get(b)!;
        if (da !== db) return db - da;
        return a < b ? -1 : a > b ? 1 : 0;
      });
      if (sortedRefs.length > 0) {
        rec.refs = sortedRefs;
        if (e.hasRefsAt) {
          let maxRa = -1;
          const orderedAts: Record<string, number> = {};
          for (const r of sortedRefs) {
            const v = e.refAts.get(r)!;
            if (v > maxRa) maxRa = v;
            orderedAts[r] = v;
          }
          if (maxRa >= 0) rec.refsAt = maxRa;
          rec.refAts = orderedAts;
        }
      }
      if (e.hasAt) rec.updatedAt = e.at;
      if (delAt !== undefined) rec.deletedAt = delAt;
      const nc = maxNoteCleared.get(name);
      if (nc !== undefined) rec.noteClearedAt = nc;
      const rc = maxRefsCleared.get(name);
      if (rc !== undefined) rec.refsClearedAt = rc;
      out.push(JSON.stringify(rec));
    } else if (delAt !== undefined) {
      out.push(JSON.stringify({ name, deleted: true, updatedAt: delAt }));
    }
  }
  for (const line of extra) out.push(line);
  return out.length === 0 ? "" : `${out.join("\n")}\n`;
}

export function decide(path: string, mine: Rec | undefined, theirs: Rec, contentOf: (hash: string) => Buffer | null, nameOf: (station: string) => string): Outcome {
  if (mine === undefined) return { kind: "take", rec: theirs };
  if (mine.hash === theirs.hash) return newer(theirs, mine) ? { kind: "take", rec: theirs } : { kind: "keep" };
  if (theirs.prev.includes(mine.hash) && mine.hash !== "") return { kind: "take", rec: theirs };
  if (mine.prev.includes(theirs.hash) && theirs.hash !== "") return { kind: "keep" };
  // Deleted on one and still there on the other: what is there stays (an edit is not lost to a delete).
  if (theirs.hash === "" && mine.hash === "") return newer(theirs, mine) ? { kind: "take", rec: theirs } : { kind: "keep" };
  const [w, l] = newer(theirs, mine) ? [theirs, mine] : [mine, theirs];
  const at = Math.max(w.at, l.at) + 1;
  const made = (content: Buffer | null, prevOf: Rec[]): Rec => ({
    hash: content === null ? "" : sha(content),
    at,
    by: w.by,
    prev: [...new Set(prevOf.flatMap(history))].slice(0, PREV_MOST * 2),
    size: content?.length ?? 0,
    mode: (w.hash !== "" ? w : l).mode,
  });
  if (w.hash === "" || l.hash === "") {
    const kept = w.hash === "" ? l : w;
    const content = contentOf(kept.hash);
    if (content === null) return { kind: "keep" };
    return { kind: "merge", rec: made(content, [w, l]), content, beside: null };
  }
  const wc = contentOf(w.hash);
  const lc = contentOf(l.hash);
  if (wc === null || lc === null) return { kind: "keep" };
  const lh = history(l);
  const common = lh.find((h) => history(w).includes(h));
  const base = common === undefined ? null : contentOf(common);
  let text: string | null = null;
  if (isText(wc) && isText(lc)) {
    if (base !== null && isText(base)) {
      text = merge3(base.toString("utf8"), wc.toString("utf8"), lc.toString("utf8"));
      if (text === null && path === "PROJECTS.jsonl") {
        text = unionLines(wc.toString("utf8"), lc.toString("utf8"), null, null);
      }
    } else if (common !== undefined || path === "PROJECTS.jsonl") {
      text = unionLines(wc.toString("utf8"), lc.toString("utf8"), null, null);
    } else if (path === "MEMORY.md") {
      text = unionLines(wc.toString("utf8"), lc.toString("utf8"), w.origin ? nameOf(w.by) : null, l.origin ? nameOf(l.by) : null);
    } else if (alike(wc.toString("utf8"), lc.toString("utf8"))) {
      text = unionLines(wc.toString("utf8"), lc.toString("utf8"), null, null);
    }
  }
  if (text !== null) {
    const finalText = path === "MEMORY.md" ? dedupMemoryLines(text) : text;
    let content = Buffer.from(finalText, "utf8");
    if (path === "PROJECTS.jsonl" && content.length > FILE_MOST) {
      content = Buffer.from(compactProjectsJsonl(finalText), "utf8");
      if (content.length > FILE_MOST) return { kind: "keep" };
    }
    return { kind: "merge", rec: made(content, [w, l]), content, beside: null };
  }
  const besidePath = conflictPath(path, nameOf(l.by));
  const besideRec: Rec = { hash: sha(lc), at, by: w.by, prev: [], size: lc.length, mode: l.mode };
  return { kind: "merge", rec: made(wc, [w, l]), content: wc, beside: memoryPath(besidePath) ? { path: besidePath, rec: besideRec, content: lc } : null };
}

/// The memory's files in `dir` as they are now (path → bytes and mode), and the skills that are not shared as they
/// are (too large, a link): MemorySync's `#read`.
export async function readMemory(dir: string): Promise<{ files: Map<string, { bytes: Buffer; mode: number; mtime: number }>; held: Set<string> }> {
  const files = new Map<string, { bytes: Buffer; mode: number; mtime: number }>();
  const held = new Set<string>();
  try {
    const st = await lstat(join(dir, "MEMORY.md"));
    if (!st.isFile()) {}
    else if (st.size <= FILE_MOST) files.set("MEMORY.md", { bytes: await readFile(join(dir, "MEMORY.md")), mode: modeOf(st.mode), mtime: Math.round(st.mtimeMs) });
    else held.add("MEMORY.md");
  } catch {}
  try {
    const st = await lstat(join(dir, "PROJECTS.jsonl"));
    if (!st.isFile()) {}
    else if (own(st.mode) || st.size > FILE_MOST) held.add("PROJECTS.jsonl");
    else files.set("PROJECTS.jsonl", { bytes: await readFile(join(dir, "PROJECTS.jsonl")), mode: modeOf(st.mode), mtime: Math.round(st.mtimeMs) });
  } catch {}
  let skills: Dirent[] = [];
  try {
    skills = await readdir(join(dir, "skills"), { withFileTypes: true });
  } catch {}
  for (const skill of skills) {
    const prefix = `skills/${skill.name}/`;
    if (BUILTIN.has(skill.name) || !portableName(skill.name) || SKIPPED.has(skill.name)) continue;
    if (!skill.isDirectory()) {
      held.add(prefix);
      continue;
    }
    const found = new Map<string, { bytes: Buffer; mode: number; mtime: number }>();
    let bytes = 0;
    let over = false;
    const walk = async (rel: string) => {
      let entries: Dirent[] = [];
      try {
        entries = await readdir(join(dir, "skills", skill.name, rel), { withFileTypes: true });
      } catch {
        return;
      }
      for (const e of entries) {
        if (over || !portableName(e.name) || SKIPPED.has(e.name)) continue;
        const sub = rel === "" ? e.name : `${rel}/${e.name}`;
        if (e.isDirectory()) await walk(sub);
        else if (e.isFile()) {
          const full = join(dir, "skills", skill.name, sub);
          const st = await lstat(full);
          if (own(st.mode)) continue;
          bytes += st.size;
          if (st.size > FILE_MOST || bytes > SKILL_MOST || found.size >= SKILL_FILES) over = true;
          else found.set(prefix + sub, { bytes: await readFile(full), mode: modeOf(st.mode), mtime: Math.round(st.mtimeMs) });
        }
      }
    };
    await walk("");
    if (over || !found.has(`${prefix}SKILL.md`)) held.add(prefix);
    else for (const [p, f] of found) files.set(p, f);
  }
  return { files, held };
}
