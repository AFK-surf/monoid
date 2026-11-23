// Local station override metadata (<app>/OVERRIDE) and conditional auto-update rules (`autoUpdateWhen` in config.json).
// Pure parsing, formatting, and matching functions shared by Updates, admin routes, CLI status, and `stillfail replace`.
import { readFileSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import type { Release } from "../../../shared/release-signed.ts";

export type OverrideMeta = {
  baseVersion: string | null;
  baseBuild: number | null;
  baseCommit: string | null;
  kind: "bundle" | "overlay";
  replacedAt: number;
  note?: string;
};

export type WaitCondition =
  | { kind: "pr"; value: number }
  | { kind: "fix"; value: number }
  | { kind: "commit"; value: string }
  | { kind: "version"; value: string }
  | { kind: "after"; value: string };

export type AutoUpdateWhen = {
  wait: WaitCondition[];
  restoreAuto: boolean;
  forOverride?: boolean;
  setAt?: number;
};

export type ReleaseIncluded = {
  build: number;
  commit: string;
  baseBuild: number;
  baseCommit: string;
  windowFromBuild: number;
  prs: number[];
  fixes: number[];
  commits: string[];
};

const VERSION_RE = /^0\.\d+\.(\d+)$/;
const HEX_COMMIT_RE = /^[0-9a-f]{7,40}$/i;

export function versionBuild(version: string | null | undefined): number | null {
  const m = VERSION_RE.exec(version ?? "");
  if (!m) return null;
  const n = Number(m[1]);
  return Number.isSafeInteger(n) ? n : null;
}

export function parseOverrideJson(text: string): OverrideMeta | null {
  try {
    const raw = JSON.parse(text);
    if (typeof raw !== "object" || raw === null) return null;
    const kind = raw.kind === "bundle" || raw.kind === "overlay" ? raw.kind : null;
    if (kind === null) return null;
    const baseVersion = typeof raw.baseVersion === "string" && raw.baseVersion.trim() !== "" ? raw.baseVersion.trim() : null;
    const baseBuild = Number.isSafeInteger(raw.baseBuild) ? (raw.baseBuild as number) : versionBuild(baseVersion);
    const baseCommit = typeof raw.baseCommit === "string" && raw.baseCommit.trim() !== "" ? raw.baseCommit.trim() : null;
    const replacedAt = typeof raw.replacedAt === "number" && Number.isFinite(raw.replacedAt) ? raw.replacedAt : 0;
    const note = typeof raw.note === "string" && raw.note.trim() !== "" ? raw.note.trim() : undefined;
    return { baseVersion, baseBuild, baseCommit, kind, replacedAt, ...(note !== undefined ? { note } : {}) };
  } catch {
    return null;
  }
}

export function readOverrideSync(app: string): OverrideMeta | null {
  try {
    return parseOverrideJson(readFileSync(join(app, "OVERRIDE"), "utf8")); // sync: read once as the station starts, before it serves
  } catch {
    return null;
  }
}

export async function readOverrideSoon(app: string): Promise<OverrideMeta | null> {
  try {
    return parseOverrideJson(await readFile(join(app, "OVERRIDE"), "utf8"));
  } catch {
    return null;
  }
}

export function parseWaitSpec(spec: string): WaitCondition {
  const s = spec.trim();
  const pr = /^(?:pr:|#)(\d+)$/i.exec(s);
  if (pr) {
    const n = Number(pr[1]);
    if (Number.isSafeInteger(n) && n > 0) return { kind: "pr", value: n };
  }
  const fix = /^(?:fix:(?:FB-?)?|FB-?)(\d+)$/i.exec(s);
  if (fix) {
    const n = Number(fix[1]);
    if (Number.isSafeInteger(n) && n > 0) return { kind: "fix", value: n };
  }
  const commit = /^commit:([0-9a-f]{7,40})$/i.exec(s);
  if (commit) {
    return { kind: "commit", value: commit[1]!.toLowerCase() };
  }
  const ver = /^(?:version:)?(0\.\d+\.\d+)$/i.exec(s);
  if (ver && versionBuild(ver[1]) !== null) {
    return { kind: "version", value: ver[1]! };
  }
  const after = /^after:(0\.\d+\.\d+)$/i.exec(s);
  if (after && versionBuild(after[1]) !== null) {
    return { kind: "after", value: after[1]! };
  }
  throw new Error(`invalid wait condition: ${spec} (expected pr:N, #N, fix:FB-N, FB-N, commit:SHA, version:0.1.N, or after:0.1.N)`);
}

export function formatWaitCondition(c: WaitCondition): string {
  switch (c.kind) {
    case "pr":
      return `#${c.value}`;
    case "fix":
      return `FB-${c.value}`;
    case "commit":
      return `commit ${c.value.slice(0, 12)}`;
    case "version":
      return `>= ${c.value}`;
    case "after":
      return `> ${c.value}`;
  }
}

export function parseWaitCondition(raw: unknown): WaitCondition | null {
  if (typeof raw !== "object" || raw === null) return null;
  const r = raw as Record<string, unknown>;
  if ((r.kind === "pr" || r.kind === "fix") && Number.isSafeInteger(r.value) && (r.value as number) > 0) {
    return { kind: r.kind, value: r.value as number };
  }
  if (r.kind === "commit" && typeof r.value === "string" && HEX_COMMIT_RE.test(r.value)) {
    return { kind: "commit", value: r.value.toLowerCase() };
  }
  if ((r.kind === "version" || r.kind === "after") && typeof r.value === "string" && versionBuild(r.value) !== null) {
    return { kind: r.kind, value: r.value };
  }
  return null;
}

export function parseAutoUpdateWhen(raw: any): AutoUpdateWhen | null {
  const w = raw?.autoUpdateWhen;
  if (typeof w !== "object" || w === null || !Array.isArray(w.wait)) return null;
  const wait: WaitCondition[] = [];
  for (const item of w.wait) {
    const parsed = parseWaitCondition(item);
    if (parsed !== null) wait.push(parsed);
  }
  const out: AutoUpdateWhen = {
    wait,
    restoreAuto: w.restoreAuto === true,
  };
  if (w.forOverride === true) out.forOverride = true;
  if (typeof w.setAt === "number" && Number.isFinite(w.setAt)) out.setAt = w.setAt;
  return out;
}

export function needsIncluded(wait: readonly WaitCondition[]): boolean {
  return wait.some((c) => c.kind === "pr" || c.kind === "fix" || c.kind === "commit");
}

function commitMatches(target: string, candidate: string): boolean {
  const a = target.toLowerCase();
  const b = candidate.toLowerCase();
  if (a.length < 7 || b.length < 7) return false;
  return b.startsWith(a) || a.startsWith(b);
}

export function conditionsMet(wait: readonly WaitCondition[], release: Release, included: ReleaseIncluded | null): boolean {
  if (wait.length === 0) return false;
  for (const c of wait) {
    switch (c.kind) {
      case "version": {
        const n = versionBuild(c.value);
        if (n === null || release.build < n) return false;
        break;
      }
      case "after": {
        const n = versionBuild(c.value);
        if (n === null || release.build <= n) return false;
        break;
      }
      case "pr":
        if (included === null || !included.prs.includes(c.value)) return false;
        break;
      case "fix":
        if (included === null || !included.fixes.includes(c.value)) return false;
        break;
      case "commit": {
        const direct = typeof release.commit === "string" && commitMatches(c.value, release.commit);
        const inList = included !== null && included.commits.some((ic) => commitMatches(c.value, ic));
        if (!direct && !inList) return false;
        break;
      }
    }
  }
  return true;
}

export function parseReleaseIncluded(raw: unknown): ReleaseIncluded | null {
  if (typeof raw !== "object" || raw === null) return null;
  const r = raw as Record<string, unknown>;
  if (!Number.isSafeInteger(r.build) || typeof r.commit !== "string" || !Array.isArray(r.prs) || !Array.isArray(r.fixes) || !Array.isArray(r.commits)) {
    return null;
  }
  return {
    build: r.build as number,
    commit: r.commit,
    baseBuild: Number.isSafeInteger(r.baseBuild) ? (r.baseBuild as number) : (r.build as number),
    baseCommit: typeof r.baseCommit === "string" ? r.baseCommit : r.commit,
    windowFromBuild: Number.isSafeInteger(r.windowFromBuild) ? (r.windowFromBuild as number) : 0,
    prs: r.prs.filter((x): x is number => Number.isSafeInteger(x)),
    fixes: r.fixes.filter((x): x is number => Number.isSafeInteger(x)),
    commits: r.commits.filter((x): x is string => typeof x === "string").map((s) => s.toLowerCase()),
  };
}
