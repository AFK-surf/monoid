// Daily local branch cleanup for shared clones in `<data>/repos` and 30-day bundle retention in `<data>/repo-bundles`.
// Reclaims branches that are already on a remote, upstream-applied (cherry / merge-tree), process-file-only, or stale
// unpushed (> 14 days, archived into a verified git bundle before deletion). Used both by `Upkeep` (once per day) and
// by `relieveRepos` (unthrottled on candidate clones before checking whether any unpushed branches remain).
import { lstat, mkdir, readdir, realpath, rm, stat, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { startEnv } from "./agent-env.ts";
import { wall } from "./fibers.ts";
import { log } from "./log.ts";
import { endCommand, startCommand } from "./processes.ts";
import { platform } from "../platform/index.ts";
import { inside } from "./paths.ts";
import { yieldLoop } from "./walk.ts";

const HOUR = 3_600_000;
const DAY = 24 * HOUR;

/// How often `Upkeep` cleans local branches in shared clones (once per day; also runs on the first round after startup).
export const REPO_BRANCHES_EVERY_MS = DAY;
/// Minimum age since a branch was last touched before it may be pruned (24h, protecting freshly created branches
/// before a session attaches a worktree).
export const BRANCH_MIN_AGE_MS = DAY;
/// Age threshold for archiving and deleting stale unpushed branches without a same-named remote branch (14 days).
export const STALE_BRANCH_MS = 14 * DAY;
/// Retention window for git bundles created from pruned stale unpushed branches (30 days).
export const REPO_BUNDLE_MS = 30 * DAY;
/// Max local branches processed per shared clone per cleanup round; remaining branches continue the next day.
export const REPO_BRANCHES_MAX_PER_REPO = 500;
/// Short deadline for local read-only / ref-update git checks during branch cleanup and low-disk clone reclamation.
export const REPO_GIT_TIMEOUT_MS = 15_000;
/// Deadline for the station's own `git gc --auto` in a shared clone (30 minutes: a first repack of a large clone
/// with many worktrees on a small machine takes minutes; one stopped at the deadline is done again the next round).
export const REPO_GC_TIMEOUT_MS = 30 * 60_000;
/// git's own thresholds, given only to the station's gc (`gc.auto=0` in the clone turns them off for everyone else).
const GC_LOOSE_MOST = 6700;
const GC_PACKS_MOST = 50;

/// Process-file paths created by agents rather than project deliverables (per requester:
/// 「agent自己的历史报告/临时记录/交接账本之类的」). Never includes `.claude`, `.codex`, `docs/`, etc.
export const PROCESS_DIR_SEGMENTS: ReadonlySet<string> = new Set([".agent", "scratch", "scratchpad", "tmp", ".tmp"]);
export const PROCESS_FILE_RE =
  /^(HANDOFF|HANDOVER|LEDGER|NOTES?|REPORT|PLAN|TODO|PROGRESS|STATUS|SUMMARY|JOURNAL|WORKLOG)[-_.A-Za-z0-9]*\.(md|txt|log|json)$/i;

/// Whether a repository-relative path is a temporary/process artifact rather than substantive project content.
export function isProcessFile(relPath: string): boolean {
  const parts = relPath.split(/[/\\]+/).filter((p) => p !== "" && p !== ".");
  if (parts.length === 0) return false;
  for (const seg of parts) {
    if (PROCESS_DIR_SEGMENTS.has(seg)) return true;
  }
  const base = parts[parts.length - 1]!;
  if (base.toLowerCase().endsWith(".log")) return true;
  return PROCESS_FILE_RE.test(base);
}

export type RepoGitRun = (dir: string, args: string[], timeoutMs?: number, background?: boolean) => Promise<{ ok: boolean; stdout: string }>;

/// How long git is given to end on SIGTERM past its deadline (removing its temporary packs) before SIGKILL.
const REPO_GIT_TERM_GRACE_MS = 10_000;

/// Runs a local git command in `dir` with interactive prompts disabled and a hard timeout, `background` as the
/// system's background work (platform.backgrounded). git runs as a group of its own and is ended whole at the
/// deadline: `gc` starts `repack` and `pack-objects`, which a kill of git alone leaves running (holding its stdout, so
/// it would not even be heard to close).
export const runRepoGit: RepoGitRun = (dir, args, timeoutMs = REPO_GIT_TIMEOUT_MS, background = false) =>
  new Promise((resolve) => {
    const env = { ...startEnv(), GIT_TERMINAL_PROMPT: "0", GIT_SSH_COMMAND: "ssh -oBatchMode=yes -oStrictHostKeyChecking=accept-new" };
    const [program, argv] = background ? platform.backgrounded("git", ["-C", dir, ...args]) : ["git", ["-C", dir, ...args]];
    const child = startCommand(program, argv, { env, stdio: ["ignore", "pipe", "ignore"] });
    let stdout = "";
    let late = false;
    let kill: (() => void) | undefined;
    // timer: a deadline to a process (local git check / bundle / gc given timeoutMs at most)
    const stop = wall.after(timeoutMs, () => {
      late = true;
      endCommand(child, "SIGTERM");
      // timer: a deadline to a process (what git has not ended in its grace after SIGTERM)
      kill = wall.after(REPO_GIT_TERM_GRACE_MS, () => endCommand(child, "SIGKILL"));
    });
    const done = (ok: boolean) => {
      stop();
      kill?.();
      resolve({ ok, stdout });
    };
    // (heard before its streams: one not started (ENFILE, EMFILE) has none, and its error told to none ends the station)
    child.on("error", () => done(false));
    child.on("close", (code) => done(!late && code === 0));
    child.stdout?.setEncoding("utf8");
    child.stdout?.on("data", (d: string) => {
      if (stdout.length < 512 * 1024) stdout += d;
    });
  });

export type RepoBranchCleanupSummary = {
  repo: string;
  deletedRemote: number;
  deletedCherry: number;
  deletedMerged: number;
  deletedProcessOnly: number;
  deletedStaleBundled: number;
  bundlePath: string | null;
};

function utcStamp(ms: number): string {
  return new Date(ms).toISOString().replace(/:/g, "-").replace(/\.\d{3}Z$/, "Z");
}

async function uniqueBundleBase(dir: string, ms: number): Promise<string> {
  const base = utcStamp(ms);
  for (let i = 0; i < 100; i++) {
    const stem = i === 0 ? base : `${base}-${i}`;
    const bundle = join(dir, `${stem}.bundle`);
    const txt = join(dir, `${stem}.txt`);
    const [bSt, tSt] = await Promise.all([lstat(bundle).catch(() => null), lstat(txt).catch(() => null)]);
    if (bSt === null && tSt === null) return stem;
  }
  return `${base}-${wall.now()}`;
}

async function branchLastChangedMs(repoPath: string, ref: string, git: RepoGitRun): Promise<number> {
  // Check `git reflog exists` first (`git reflog show` falls back to commit date when no reflog exists),
  // and use `--date=unix --format=%gd` (`<name>@{<unix>}`) because `%ct` prints the commit's committer date,
  // not the reflog entry timestamp when the branch ref was created/updated.
  const hasReflog = await git(repoPath, ["reflog", "exists", ref]);
  if (hasReflog.ok) {
    const reflog = await git(repoPath, ["reflog", "show", "-1", "--date=unix", "--format=%gd", ref]);
    if (reflog.ok) {
      const m = /@\{(\d+)\}/.exec(reflog.stdout);
      if (m) {
        const sec = Number.parseInt(m[1]!, 10);
        if (Number.isFinite(sec) && sec > 0) return sec * 1000;
      }
    }
  }
  const refPath = join(repoPath, ".git", ...ref.split("/"));
  const st = await stat(refPath).catch(() => null);
  if (st !== null) return st.mtimeMs;
  // Packed ref with no reflog: treat as old enough.
  return 0;
}

/// Cleans eligible local branches in one shared clone `repoPath` under `<data>/repos/<repoName>`.
/// Returns `null` if git enumeration fails (fail closed: nothing deleted).
export async function pruneRepoBranchesIn(
  data: string,
  repoName: string,
  repoPath: string,
  now: number,
  options?: { git?: RepoGitRun; maxBranches?: number; minAgeMs?: number; staleMs?: number },
): Promise<RepoBranchCleanupSummary | null> {
  const git = options?.git ?? runRepoGit;
  const maxBranches = options?.maxBranches ?? REPO_BRANCHES_MAX_PER_REPO;
  const minAgeMs = options?.minAgeMs ?? BRANCH_MIN_AGE_MS;
  const staleMs = options?.staleMs ?? STALE_BRANCH_MS;

  // 2. Protected branches: every branch checked out by any registered worktree (including missing/locked) + main HEAD.
  const wtRes = await git(repoPath, ["worktree", "list", "--porcelain"]);
  if (!wtRes.ok) return null;
  const protectedRefs = new Set<string>();
  for (const line of wtRes.stdout.split(/\r?\n/)) {
    if (line.startsWith("branch refs/heads/")) {
      protectedRefs.add(line.slice("branch ".length).trim());
    }
  }
  const headRes = await git(repoPath, ["symbolic-ref", "-q", "HEAD"]);
  if (headRes.ok) {
    const headRef = headRes.stdout.trim();
    if (headRef.startsWith("refs/heads/")) protectedRefs.add(headRef);
  }

  // Enumerate local branches with tip sha and committer unix timestamp.
  const refsRes = await git(repoPath, ["for-each-ref", "--format=%(refname)\t%(objectname)\t%(committerdate:unix)", "refs/heads"]);
  if (!refsRes.ok) return null;
  const branches: { ref: string; shortName: string; sha: string; commitMs: number }[] = [];
  for (const line of refsRes.stdout.split(/\r?\n/)) {
    if (line === "") continue;
    const [ref, sha, secStr] = line.split("\t");
    if (!ref || !sha || !ref.startsWith("refs/heads/")) continue;
    const sec = Number.parseInt(secStr ?? "", 10);
    branches.push({
      ref,
      shortName: ref.slice("refs/heads/".length),
      sha,
      commitMs: Number.isFinite(sec) && sec > 0 ? sec * 1000 : 0,
    });
  }

  // Enumerate remote branch names once for step 7 (fail closed if listing fails).
  const remoteRefsRes = await git(repoPath, ["for-each-ref", "--format=%(refname)", "refs/remotes"]);
  const remoteListOk = remoteRefsRes.ok;
  const remoteBranchNames = new Set<string>();
  if (remoteListOk) {
    for (const line of remoteRefsRes.stdout.split(/\r?\n/)) {
      if (!line.startsWith("refs/remotes/")) continue;
      const rest = line.slice("refs/remotes/".length);
      const slash = rest.indexOf("/");
      if (slash <= 0) continue;
      const name = rest.slice(slash + 1);
      if (name !== "" && name !== "HEAD") remoteBranchNames.add(name);
    }
  }

  // 4. Default branch: refs/remotes/origin/HEAD, else origin/main, else origin/master.
  let defaultBranch: string | null = null;
  const symOrigin = await git(repoPath, ["symbolic-ref", "-q", "--short", "refs/remotes/origin/HEAD"]);
  if (symOrigin.ok && symOrigin.stdout.trim() !== "") {
    defaultBranch = symOrigin.stdout.trim();
  } else if ((await git(repoPath, ["rev-parse", "--verify", "-q", "refs/remotes/origin/main"])).ok) {
    defaultBranch = "origin/main";
  } else if ((await git(repoPath, ["rev-parse", "--verify", "-q", "refs/remotes/origin/master"])).ok) {
    defaultBranch = "origin/master";
  }
  let defaultTree: string | null = null;
  if (defaultBranch !== null) {
    const treeRes = await git(repoPath, ["rev-parse", "-q", `${defaultBranch}^{tree}`]);
    if (treeRes.ok && treeRes.stdout.trim() !== "") defaultTree = treeRes.stdout.trim();
  }

  const summary: RepoBranchCleanupSummary = {
    repo: repoName,
    deletedRemote: 0,
    deletedCherry: 0,
    deletedMerged: 0,
    deletedProcessOnly: 0,
    deletedStaleBundled: 0,
    bundlePath: null,
  };

  const staleBatch: { ref: string; shortName: string; sha: string }[] = [];
  let processed = 0;

  for (const b of branches) {
    if (processed >= maxBranches) break;
    if (protectedRefs.has(b.ref)) continue;
    processed++;

    // 3. Too fresh (< 24h) -> skip.
    const lastChanged = await branchLastChangedMs(repoPath, b.ref, git);
    if (now - lastChanged < minAgeMs) continue;

    // 5a. Tip already on a remote.
    const onRemote = await git(repoPath, ["rev-list", "--count", "-n", "1", b.ref, "--not", "--remotes"]);
    if (onRemote.ok && onRemote.stdout.trim() === "0") {
      if ((await git(repoPath, ["update-ref", "-d", b.ref, b.sha])).ok) summary.deletedRemote++;
      continue;
    }

    // 5b-d require a known default branch.
    if (defaultBranch !== null) {
      // 5b. Patch already upstream (no '+' lines from git cherry).
      const cherry = await git(repoPath, ["cherry", defaultBranch, b.ref]);
      if (cherry.ok) {
        const hasUnapplied = cherry.stdout.split(/\r?\n/).some((l) => l.startsWith("+"));
        if (!hasUnapplied) {
          if ((await git(repoPath, ["update-ref", "-d", b.ref, b.sha])).ok) summary.deletedCherry++;
          continue;
        }
      }

      // 5c. Merge-tree produces identical tree to default branch.
      if (defaultTree !== null) {
        const mergeTree = await git(repoPath, ["merge-tree", "--write-tree", defaultBranch, b.ref]);
        if (mergeTree.ok && (mergeTree.stdout.split(/\r?\n/)[0]?.trim() ?? "") === defaultTree) {
          if ((await git(repoPath, ["update-ref", "-d", b.ref, b.sha])).ok) summary.deletedMerged++;
          continue;
        }
      }

      // 5d. Empty diff or only process files since merge-base with default branch.
      const mb = await git(repoPath, ["merge-base", defaultBranch, b.ref]);
      const baseSha = mb.ok ? mb.stdout.trim() : "";
      if (baseSha !== "") {
        const diff = await git(repoPath, ["-c", "core.quotepath=false", "diff", "--name-only", baseSha, b.ref]);
        if (diff.ok) {
          const paths = diff.stdout.split(/\r?\n/).filter((l) => l !== "");
          if (paths.length === 0 || paths.every(isProcessFile)) {
            if ((await git(repoPath, ["update-ref", "-d", b.ref, b.sha])).ok) summary.deletedProcessOnly++;
            continue;
          }
        }
      }
    }

    // 7. Stale unpushed branch (> 14 days, no same-named remote branch) -> archive into bundle before deleting.
    if (remoteListOk && !remoteBranchNames.has(b.shortName) && b.commitMs > 0 && now - b.commitMs >= staleMs) {
      staleBatch.push({ ref: b.ref, shortName: b.shortName, sha: b.sha });
    }
  }

  // Create & verify one bundle per clone per round for all stale unpushed branches; delete only if create + verify + txt succeed.
  if (staleBatch.length > 0) {
    const bundleDir = join(data, "repo-bundles", repoName);
    let bundleFile = "";
    let manifestFile = "";
    try {
      await mkdir(bundleDir, { recursive: true });
      const stem = await uniqueBundleBase(bundleDir, now);
      bundleFile = join(bundleDir, `${stem}.bundle`);
      manifestFile = join(bundleDir, `${stem}.txt`);
      const createRes = await git(repoPath, ["bundle", "create", bundleFile, ...staleBatch.map((b) => b.ref), "--not", "--remotes"]);
      if (!createRes.ok) {
        log.warn("upkeep", "creating git bundle for stale branches failed; keeping branches", { repo: repoName, count: staleBatch.length });
        await rm(bundleFile, { force: true }).catch(() => undefined);
      } else {
        const verifyRes = await git(repoPath, ["bundle", "verify", bundleFile]);
        if (!verifyRes.ok) {
          log.warn("upkeep", "verifying git bundle for stale branches failed; keeping branches", { repo: repoName, bundle: bundleFile });
          await rm(bundleFile, { force: true }).catch(() => undefined);
        } else {
          const lines = [
            ...staleBatch.map((b) => `${b.shortName} ${b.sha}`),
            `# Restore: git fetch ${bundleFile} 'refs/heads/*:refs/heads/*'`,
          ];
          await writeFile(manifestFile, `${lines.join("\n")}\n`, "utf8");
          summary.bundlePath = bundleFile;
          for (const b of staleBatch) {
            if ((await git(repoPath, ["update-ref", "-d", b.ref, b.sha])).ok) summary.deletedStaleBundled++;
          }
        }
      }
    } catch (error) {
      log.warn("upkeep", "archiving stale branches into bundle failed; keeping branches", { repo: repoName, error: (error as Error).message });
      if (bundleFile !== "") await rm(bundleFile, { force: true }).catch(() => undefined);
      if (manifestFile !== "") await rm(manifestFile, { force: true }).catch(() => undefined);
    }
  }

  const totalDeleted =
    summary.deletedRemote +
    summary.deletedCherry +
    summary.deletedMerged +
    summary.deletedProcessOnly +
    summary.deletedStaleBundled;

  // 8. One info log per clone summarizing counts and bundle path (the clone's gc is `keepSharedClonePacks`, each `Upkeep` round).
  if (totalDeleted > 0) {
    log.info("upkeep", "cleaned local branches in shared clone", {
      repo: repoName,
      remote: summary.deletedRemote,
      cherry: summary.deletedCherry,
      merged: summary.deletedMerged,
      processOnly: summary.deletedProcessOnly,
      staleBundled: summary.deletedStaleBundled,
      bundle: summary.bundlePath ?? "",
    });
  }

  return summary;
}

/// Cleans local branches across all shared clones in `<data>/repos` (skipping symlinks, dotfiles / `.cloning-*`, and
/// whenever a clone is in progress). Yields between clones.
export async function pruneAllRepoBranches(
  data: string,
  now: number,
  options?: {
    clonesActive?: () => boolean;
    pruneWorktrees?: (data: string) => Promise<unknown>;
    git?: RepoGitRun;
    maxBranches?: number;
    minAgeMs?: number;
    staleMs?: number;
  },
): Promise<RepoBranchCleanupSummary[]> {
  if (options?.clonesActive?.()) return [];
  const realData = await realpath(data).catch(() => null);
  if (realData === null) return [];
  const realRepos = await realpath(join(realData, "repos")).catch(() => null);
  if (realRepos === null || !inside(realRepos, realData)) return [];

  if (options?.pruneWorktrees) await options.pruneWorktrees(data);

  const results: RepoBranchCleanupSummary[] = [];
  for (const name of await readdir(realRepos).catch(() => [] as string[])) {
    if (options?.clonesActive?.()) break;
    if (name.startsWith(".")) continue;
    const repoPath = join(realRepos, name);
    const st = await lstat(repoPath).catch(() => null);
    if (st === null || !st.isDirectory() || st.isSymbolicLink()) continue;
    const realRepo = await realpath(repoPath).catch(() => null);
    if (realRepo === null || !inside(realRepo, realData)) continue;
    const summary = await pruneRepoBranchesIn(data, name, realRepo, now, options);
    if (summary !== null) results.push(summary);
    await yieldLoop();
  }
  return results;
}

/// `keepSharedClonePacks` for every shared clone in `<data>/repos` (as `pruneAllRepoBranches` finds them), one at a
/// time, each `Upkeep` round; `daily` on the round that also cleans branches. `failed` holds the clones whose last gc
/// failed or was stopped at its deadline: only the daily round tries those again, not every round for 30 minutes.
export async function keepAllSharedClonePacks(
  data: string,
  options?: { daily?: boolean; failed?: Set<string>; clonesActive?: () => boolean; git?: RepoGitRun },
): Promise<void> {
  if (options?.clonesActive?.()) return;
  const realData = await realpath(data).catch(() => null);
  if (realData === null) return;
  const realRepos = await realpath(join(realData, "repos")).catch(() => null);
  if (realRepos === null || !inside(realRepos, realData)) return;
  for (const name of await readdir(realRepos).catch(() => [] as string[])) {
    if (options?.clonesActive?.()) return;
    if (name.startsWith(".")) continue;
    const repoPath = join(realRepos, name);
    const st = await lstat(repoPath).catch(() => null);
    if (st === null || !st.isDirectory() || st.isSymbolicLink()) continue;
    const realRepo = await realpath(repoPath).catch(() => null);
    if (realRepo === null || !inside(realRepo, realData)) continue;
    if ((await stat(join(realRepo, ".git")).catch(() => null)) === null) continue;
    const daily = options?.daily ?? false;
    if (!daily && options?.failed?.has(realRepo)) continue;
    const ok = await keepSharedClonePacks(name, realRepo, daily, options?.git);
    if (ok) options?.failed?.delete(realRepo);
    else options?.failed?.add(realRepo);
    await yieldLoop();
  }
}

/// The packs of a clone git counts toward `gc.autoPackLimit`: those without a `.keep`.
async function packsCounted(repoPath: string): Promise<number> {
  const names = await readdir(join(repoPath, ".git", "objects", "pack")).catch(() => [] as string[]);
  const kept = new Set(names.filter((n) => n.endsWith(".keep")).map((n) => n.slice(0, -".keep".length)));
  return names.filter((n) => n.endsWith(".pack") && !kept.has(n.slice(0, -".pack".length))).length;
}

/// Keeps a shared clone's packs in bounds with a gc run by the station, and none run by git on its own.
///
/// Every worktree of a shared clone shares its object store, and git starts `git maintenance run --auto --detach` (a
/// detached `gc --auto`) after a commit, fetch, merge or rebase in any of them. Once the clone is past `gc.autoPackLimit`
/// (50 packs; each fetch adds one) every such command starts another full cruft repack, none waiting for the one before:
/// on a 16 GB machine dozens of them (several hundred MB each) swapped it until its station stopped answering. So the
/// clone's own config turns git's automatic maintenance off (`maintenance.auto=false`, `gc.auto=0`, inherited by every
/// worktree), and the station runs `gc --auto` itself, in the foreground under a deadline, as background work: every
/// round once the clone is past the pack limit (a gc leaves one pack, so the next round does not run it), and `daily`
/// with git's loose-object threshold too. That one is once a day as git's own detached gc keeps it (`gc.log`): loose
/// objects no longer reachable but younger than `gc.pruneExpire` stay loose after a gc, so a gc for them every round
/// would walk the whole clone again every round.
/// Whether its gc, if it ran one, succeeded.
export async function keepSharedClonePacks(repoName: string, repoPath: string, daily = true, git: RepoGitRun = runRepoGit): Promise<boolean> {
  for (const [key, value] of [["maintenance.auto", "false"], ["gc.auto", "0"]] as const) {
    const now = await git(repoPath, ["config", "--local", "--get", key]);
    if (now.ok && now.stdout.trim() === value) continue;
    if (!(await git(repoPath, ["config", "--local", key, value])).ok) log.warn("upkeep", "could not turn off git's automatic maintenance in shared clone", { repo: repoName, key });
  }
  if (!daily && (await packsCounted(repoPath)) <= GC_PACKS_MOST) return true;
  const gc = await git(
    repoPath,
    ["-c", `gc.auto=${GC_LOOSE_MOST}`, "-c", `gc.autoPackLimit=${GC_PACKS_MOST}`, "-c", "gc.autoDetach=false", "-c", "maintenance.auto=false", "gc", "--auto", "--quiet"],
    REPO_GC_TIMEOUT_MS,
    true,
  );
  if (!gc.ok) log.warn("upkeep", "git gc --auto failed in shared clone", { repo: repoName });
  return gc.ok;
}

/// Removes `.bundle` and `.txt` files under `<data>/repo-bundles/<clone>` older than `maxAgeMs` (30 days),
/// and removes empty `<clone>` subdirectories.
export async function pruneExpiredRepoBundles(data: string, now: number, maxAgeMs = REPO_BUNDLE_MS): Promise<string[]> {
  const realData = await realpath(data).catch(() => null);
  if (realData === null) return [];
  const bundlesDir = join(realData, "repo-bundles");
  const bundlesSt = await lstat(bundlesDir).catch(() => null);
  if (bundlesSt === null || !bundlesSt.isDirectory() || bundlesSt.isSymbolicLink()) return [];

  const gone: string[] = [];
  for (const cloneName of await readdir(bundlesDir).catch(() => [] as string[])) {
    if (cloneName.startsWith(".")) continue;
    const cloneDir = join(bundlesDir, cloneName);
    const cloneSt = await lstat(cloneDir).catch(() => null);
    if (cloneSt === null || !cloneSt.isDirectory() || cloneSt.isSymbolicLink()) continue;
    const entries = await readdir(cloneDir).catch(() => [] as string[]);
    let remaining = entries.length;
    for (const fileName of entries) {
      if (!fileName.endsWith(".bundle") && !fileName.endsWith(".txt")) continue;
      const filePath = join(cloneDir, fileName);
      const st = await lstat(filePath).catch(() => null);
      if (st === null || !st.isFile() || st.isSymbolicLink()) continue;
      if (now - st.mtimeMs < maxAgeMs) continue;
      const removed = await rm(filePath, { force: true }).then(() => true, () => false);
      if (removed) {
        gone.push(`${cloneName}/${fileName}`);
        remaining--;
      }
    }
    if (remaining <= 0) {
      const after = await readdir(cloneDir).catch(() => null);
      if (after !== null && after.length === 0) {
        await rm(cloneDir, { recursive: true, force: true }).catch(() => undefined);
      }
    }
  }
  gone.sort();
  return gone;
}
