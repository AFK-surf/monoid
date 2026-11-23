// Generates a station release's signed included-changes manifest: which PRs, bug-report fixes (Fixes: FB-<n>), and
// commits (including cherry-picked originals) are in the first-parent window leading up to a release commit.
// Written to a content-addressed path without channel (`station/included/<build>-<sha16>.json`) so promoting a beta
// feed to stable reuses the exact signed words and manifest without re-signing.
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { readMessage } from "./changelog.ts";

export const INCLUDED_WINDOW = 3000;

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

export type WrittenReleaseIncluded = {
  file: string;
  sha256: string;
  size: number;
  absPath: string;
  manifest: ReleaseIncluded;
};

const CHERRY_PICK = /cherry picked from commit ([0-9a-f]{7,40})/gi;
const SUBJECT_PR = /\(#(\d+)\)/g;

function git(repo: string, ...args: string[]): string {
  return execFileSync("git", args, { cwd: repo, encoding: "utf8", maxBuffer: 256 * 1024 * 1024 });
}

function gitMaybe(repo: string, ...args: string[]): string | null {
  try {
    return execFileSync("git", args, { cwd: repo, encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
  } catch {
    return null;
  }
}

export function buildReleaseIncluded(
  repo: string,
  opts: { rev?: string; build?: number; limit?: number; mainRef?: string } = {},
): ReleaseIncluded {
  const rev = opts.rev ?? "HEAD";
  const limit = opts.limit ?? INCLUDED_WINDOW;
  const commit = git(repo, "rev-parse", rev).trim().toLowerCase();
  const build = opts.build ?? Number(git(repo, "rev-list", "--count", rev).trim());

  const candidateRefs = opts.mainRef ? [opts.mainRef] : ["origin/main", "refs/heads/main"];
  let baseCommit = commit;
  let baseBuild = build;
  for (const ref of candidateRefs) {
    if (gitMaybe(repo, "rev-parse", "--verify", ref) === null) continue;
    const mb = gitMaybe(repo, "merge-base", rev, ref);
    if (mb) {
      baseCommit = mb.toLowerCase();
      baseBuild = baseCommit === commit ? build : Number(git(repo, "rev-list", "--count", baseCommit).trim());
      break;
    }
  }

  const raw = git(repo, "log", "-n", String(limit), "--first-parent", "--format=%x1e%H%x1f%s%x1f%B", rev);
  const records = raw.split("\x1e").slice(1);
  const prs = new Set<number>();
  const fixes = new Set<number>();
  const commits = new Set<string>();
  let oldestHash: string | null = null;

  for (const rec of records) {
    const [hashRaw = "", subject = "", body = ""] = rec.split("\x1f");
    const hash = hashRaw.trim().toLowerCase();
    if (!hash) continue;
    oldestHash = hash;
    commits.add(hash.slice(0, 12));
    for (const m of subject.matchAll(SUBJECT_PR)) {
      const n = Number(m[1]);
      if (Number.isSafeInteger(n) && n > 0) prs.add(n);
    }
    for (const m of body.matchAll(CHERRY_PICK)) {
      commits.add(m[1]!.slice(0, 12).toLowerCase());
    }
    const cleanBody = body.replace(/^\(cherry picked from commit [0-9a-f]{7,40}\)\s*$/gim, "");
    for (const n of readMessage(cleanBody).fixes) {
      if (Number.isSafeInteger(n) && n > 0) fixes.add(n);
    }
  }

  const windowFromBuild = oldestHash
    ? (oldestHash === commit ? build : Number(git(repo, "rev-list", "--count", oldestHash).trim()))
    : build;

  return {
    build,
    commit,
    baseBuild,
    baseCommit,
    windowFromBuild,
    prs: [...prs].sort((a, b) => a - b),
    fixes: [...fixes].sort((a, b) => a - b),
    commits: [...commits].sort(),
  };
}

export function writeReleaseIncluded(
  repo: string,
  outDir: string,
  opts: { rev?: string; build?: number; limit?: number; mainRef?: string } = {},
): WrittenReleaseIncluded {
  const manifest = buildReleaseIncluded(repo, opts);
  const bytes = Buffer.from(`${JSON.stringify(manifest)}\n`, "utf8");
  const sha256 = createHash("sha256").update(bytes).digest("hex");
  const file = `station/included/${manifest.build}-${sha256.slice(0, 16)}.json`;
  const absPath = join(outDir, file);
  mkdirSync(dirname(absPath), { recursive: true });
  writeFileSync(absPath, bytes);
  return { file, sha256, size: bytes.length, absPath, manifest };
}
