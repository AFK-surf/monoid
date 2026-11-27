// Lockless 2-generation immutable copy-on-write git worktree creation (`stillfail worktree add`).
// Populates detached worktrees by CoW-cloning a cached generation under `<common_git_dir>/cow/<oid>/`
// and running `git reset --hard -q`, falling back transparently to native `git worktree add` whenever
// any pre-flight safety gate does not pass.
import { spawn } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import { constants } from "node:fs";
import { access, copyFile, lstat, mkdir, readdir, readFile, rename, rm, stat, writeFile } from "node:fs/promises";
import { dirname, isAbsolute, join, posix, resolve } from "node:path";
import { cloneTree, sameCloneableVolume } from "../ops/clone.ts";
import { wall } from "../ops/fibers.ts";
import { platform } from "../platform/index.ts";
import { removeTree } from "./archive.ts";

const REPO_ENV = [
  "GIT_DIR",
  "GIT_WORK_TREE",
  "GIT_INDEX_FILE",
  "GIT_COMMON_DIR",
  "GIT_OBJECT_DIRECTORY",
  "GIT_ALTERNATE_OBJECT_DIRECTORIES",
  "GIT_PREFIX",
] as const;

const HEX40_RE = /^[0-9a-f]{40}$/;
const GEN_KEY_RE = /^[0-9a-f]{40}-[0-9a-f]{16}$/;
const TMP_EXPIRE_MS = 3_600_000;
const KEEP_GENERATIONS = 2;

export type WorktreeCowResult = {
  code: number;
  usedCow: boolean;
  promoted: boolean;
  hitGen: string | null;
};

function cleanGitEnv(extra?: Record<string, string>): NodeJS.ProcessEnv {
  const env: NodeJS.ProcessEnv = { ...process.env };
  for (const key of REPO_ENV) delete env[key];
  if (extra) Object.assign(env, extra);
  return env;
}

type GitExecResult = {
  code: number;
  stdout: Buffer;
  stderr: Buffer;
  stdinError?: boolean;
};

function execGit(repo: string, args: string[], opts?: { env?: Record<string, string>; input?: Buffer }): Promise<GitExecResult> {
  return new Promise((resolvePromise) => {
    const child = spawn("git", ["-C", repo, "-c", "core.fsmonitor=false", ...args], {
      env: cleanGitEnv(opts?.env),
      stdio: [opts?.input !== undefined ? "pipe" : "ignore", "pipe", "pipe"],
    });
    const outChunks: Buffer[] = [];
    const errChunks: Buffer[] = [];
    let stdinError = false;
    child.stdout?.on("data", (c: Buffer) => outChunks.push(c));
    child.stderr?.on("data", (c: Buffer) => errChunks.push(c));
    child.on("error", (err) => {
      resolvePromise({ code: 127, stdout: Buffer.alloc(0), stderr: Buffer.from(err.message), stdinError });
    });
    child.on("close", (code, signal) => {
      resolvePromise({
        code: signal ? 128 : (code ?? 1),
        stdout: Buffer.concat(outChunks),
        stderr: Buffer.concat(errChunks),
        stdinError,
      });
    });
    if (opts?.input !== undefined && child.stdin) {
      child.stdin.on("error", () => {
        stdinError = true;
      });
      child.stdin.end(opts.input);
    }
  });
}

function passthroughGit(repo: string, worktreeArgs: string[], cwd: string): Promise<number> {
  return new Promise((resolvePromise) => {
    const child = spawn("git", ["-C", repo, "worktree", ...worktreeArgs], {
      cwd,
      env: cleanGitEnv(),
      stdio: "inherit",
    });
    child.on("error", (err) => {
      process.stderr.write(`stillfail worktree: failed to run git: ${err.message}\n`);
      resolvePromise(1);
    });
    child.on("close", (code) => resolvePromise(code ?? 1));
  });
}

/// Parses `[-C <repo>] [worktree] <rest...>` or `[worktree] [-C <repo>] <rest...>`.
export function parseWorktreeArgs(argv: readonly string[], callerCwd: string): {
  repo: string;
  worktreeArgs: string[];
  fastPath: { absPath: string; commitish: string } | null;
} {
  let repoDir: string | null = null;
  let i = 0;

  // Consume optional leading `-C <repo>` and at most one `worktree` token.
  let seenWorktree = false;
  while (i < argv.length) {
    const a = argv[i]!;
    if (a === "-C" && i + 1 < argv.length) {
      repoDir = argv[i + 1]!;
      i += 2;
      continue;
    }
    if (a.startsWith("-C") && a.length > 2) {
      repoDir = a.slice(2);
      i += 1;
      continue;
    }
    if (a === "worktree" && !seenWorktree) {
      seenWorktree = true;
      i += 1;
      continue;
    }
    break;
  }

  const worktreeArgs = argv.slice(i);
  const repo = resolve(callerCwd, repoDir ?? callerCwd);

  if (process.env.STILLFAIL_WORKTREE_COW === "0") {
    return { repo, worktreeArgs, fastPath: null };
  }
  if (worktreeArgs[0] !== "add") {
    return { repo, worktreeArgs, fastPath: null };
  }

  let hasDetach = false;
  let endOpts = false;
  const positionals: string[] = [];

  for (let j = 1; j < worktreeArgs.length; j++) {
    const a = worktreeArgs[j]!;
    if (!endOpts && a === "--") {
      endOpts = true;
      continue;
    }
    if (!endOpts && a.startsWith("-")) {
      if (a === "--detach" || a === "-d") {
        hasDetach = true;
        continue;
      }
      // Any other option (-b, -B, -f, --lock, --orphan, etc.) falls back to native git.
      return { repo, worktreeArgs, fastPath: null };
    }
    positionals.push(a);
  }

  if (!hasDetach || positionals.length < 1 || positionals.length > 2) {
    return { repo, worktreeArgs, fastPath: null };
  }

  const absPath = resolve(repo, positionals[0]!);
  const commitish = positionals[1] ?? "HEAD";
  return { repo, worktreeArgs, fastPath: { absPath, commitish } };
}

async function nearestExistingAncestor(targetPath: string): Promise<string | null> {
  let cur = dirname(targetPath);
  for (;;) {
    const st = await stat(cur).catch(() => null);
    if (st !== null) return cur;
    const parent = dirname(cur);
    if (parent === cur) return null;
    cur = parent;
  }
}

async function isHookExecutable(filePath: string): Promise<boolean> {
  const st = await stat(filePath).catch(() => null);
  if (st === null || !st.isFile()) return false;
  if (platform.os === "windows") return true;
  return await access(filePath, constants.X_OK).then(
    () => true,
    () => false,
  );
}

async function readAttrFile(filePath: string): Promise<{ ok: true; text: string | null } | { ok: false }> {
  try {
    const text = await readFile(filePath, "utf8");
    return { ok: true, text };
  } catch (error) {
    const code = (error as NodeJS.ErrnoException).code;
    if (code === "ENOENT" || code === "ENOTDIR") return { ok: true, text: null };
    return { ok: false };
  }
}

function extractFilterDrivers(content: string | null): Set<string> {
  const drivers = new Set<string>();
  if (content === null) return drivers;
  for (const rawLine of content.split(/\r?\n/)) {
    const line = rawLine.trimStart();
    if (line === "" || line.startsWith("#")) continue;
    // Skip the pattern token (quoted or unquoted).
    let rest = "";
    if (line.startsWith('"')) {
      let k = 1;
      while (k < line.length) {
        if (line[k] === "\\") {
          k += 2;
          continue;
        }
        if (line[k] === '"') {
          rest = line.slice(k + 1);
          break;
        }
        k++;
      }
    } else {
      const m = /\s/.exec(line);
      if (m) rest = line.slice(m.index);
    }
    for (const token of rest.trim().split(/\s+/)) {
      if (token.startsWith("filter=") && token.length > 7) {
        drivers.add(token.slice(7));
      }
    }
  }
  return drivers;
}

function hasConfiguredFilterRule(content: string | null, configuredDrivers: Set<string>): boolean {
  if (configuredDrivers.size === 0 || content === null) return false;
  for (const d of extractFilterDrivers(content)) {
    if (configuredDrivers.has(d)) return true;
  }
  return false;
}

function parseConfiguredFilterDrivers(raw: string): Set<string> {
  const drivers = new Set<string>();
  for (const line of raw.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    const sp = trimmed.search(/\s/);
    const key = sp >= 0 ? trimmed.slice(0, sp) : trimmed;
    if (!key.startsWith("filter.")) continue;
    const rest = key.slice("filter.".length);
    const lastDot = rest.lastIndexOf(".");
    if (lastDot <= 0) continue;
    const suffix = rest.slice(lastDot + 1);
    if (suffix === "clean" || suffix === "smudge" || suffix === "process") {
      drivers.add(rest.slice(0, lastDot));
    }
  }
  return drivers;
}

async function gitConfigGet(repo: string, key: string): Promise<{ ok: true; value: string | null } | { ok: false }> {
  const res = await execGit(repo, ["config", "--get", key]);
  if (res.code === 0) return { ok: true, value: res.stdout.toString("utf8").replace(/\r?\n$/, "") };
  if (res.code === 1) return { ok: true, value: null };
  return { ok: false };
}

async function gitVarPath(repo: string, name: string): Promise<{ ok: true; path: string } | { ok: false }> {
  const res = await execGit(repo, ["var", name]);
  if (res.code !== 0) return { ok: false };
  return { ok: true, path: res.stdout.toString("utf8").trim() };
}

type HookCheckResult = { ok: true; inTreeHookPath: string | null } | { ok: false };

function hasDotDotSegment(rawPath: string): boolean {
  for (const seg of rawPath.replace(/\\/g, "/").split("/")) {
    if (seg === "..") return true;
  }
  return false;
}

async function checkPostCheckoutHook(repo: string, commonGitDir: string, absPath: string): Promise<HookCheckResult> {
  const hpRes = await gitConfigGet(repo, "core.hooksPath");
  if (!hpRes.ok) return { ok: false };
  const hp = hpRes.value;
  if (hp === null || hp === "") {
    if (await isHookExecutable(join(commonGitDir, "hooks", "post-checkout"))) return { ok: false };
    return { ok: true, inTreeHookPath: null };
  }
  if (isAbsolute(hp)) {
    if (await isHookExecutable(join(hp, "post-checkout"))) return { ok: false };
    return { ok: true, inTreeHookPath: null };
  }
  // Relative hooksPath:
  // 1) Check on disk relative to the new worktree root (catches ../hooks/post-checkout).
  if (await isHookExecutable(resolve(absPath, hp, "post-checkout"))) return { ok: false };
  // 2) Bypass conservatively if any `..` segment is present (avoids lexical collapse across symlinks).
  if (hasDotDotSegment(hp)) return { ok: false };
  const norm = posix.normalize(hp.replace(/\\/g, "/"));
  if (norm === ".." || norm.startsWith("../")) return { ok: false };
  // 3) Return in-tree path to check directly in `ls-tree -r -z` (including tracked symlink prefixes).
  const cleanRel = norm.replace(/^\.\/+/, "").replace(/\/+$/, "");
  const treePath = cleanRel === "" || cleanRel === "." ? "post-checkout" : `${cleanRel}/post-checkout`;
  return { ok: true, inTreeHookPath: treePath };
}

type PreflightOk = {
  ok: true;
  commonGitDir: string;
  commitOid: string;
  checkoutFingerprint: string;
};

async function runPreflight(repo: string, absPath: string, commitish: string): Promise<PreflightOk | { ok: false }> {
  const commonRes = await execGit(repo, ["rev-parse", "--path-format=absolute", "--git-common-dir"]);
  if (commonRes.code !== 0) return { ok: false };
  const commonGitDir = commonRes.stdout.toString("utf8").trim();
  if (!commonGitDir) return { ok: false };

  const oidRes = await execGit(repo, ["rev-parse", "--verify", `${commitish}^{commit}`], { env: { GIT_NO_LAZY_FETCH: "1" } });
  if (oidRes.code !== 0) return { ok: false };
  const commitOid = oidRes.stdout.toString("utf8").trim();
  if (!HEX40_RE.test(commitOid)) return { ok: false };

  // If absPath already exists and is non-empty (or not a directory), defer to native git error handling.
  const targetSt = await lstat(absPath).catch(() => null);
  if (targetSt !== null) {
    if (!targetSt.isDirectory()) return { ok: false };
    const entries = await readdir(absPath).catch(() => null);
    if (entries === null || entries.length > 0) return { ok: false };
  }

  // Check volume cloneability against nearest existing ancestor without mutating parent directories.
  const ancestor = await nearestExistingAncestor(absPath);
  if (ancestor === null || !(await sameCloneableVolume(commonGitDir, ancestor))) {
    return { ok: false };
  }

  // post-checkout hook gate.
  const hookCheck = await checkPostCheckoutHook(repo, commonGitDir, absPath);
  if (!hookCheck.ok) {
    return { ok: false };
  }

  // Check configured external filter drivers (`filter.<driver>.(clean|smudge|process)`).
  const filterCfgRes = await execGit(repo, ["config", "--get-regexp", "^filter\\..*\\.(clean|smudge|process)$"]);
  if (filterCfgRes.code !== 0 && filterCfgRes.code !== 1) return { ok: false };
  const filterConfigRaw = filterCfgRes.code === 0 ? filterCfgRes.stdout.toString("utf8") : "";
  const configuredDrivers = filterCfgRes.code === 0 ? parseConfiguredFilterDrivers(filterConfigRaw) : new Set<string>();

  // Global/system/info attributes + submodule & in-tree hook / .gitattributes filter gate.
  const [globalVar, systemVar] = await Promise.all([gitVarPath(repo, "GIT_ATTR_GLOBAL"), gitVarPath(repo, "GIT_ATTR_SYSTEM")]);
  if (!globalVar.ok || !systemVar.ok) return { ok: false };
  const globalAttrPath = globalVar.path;
  const systemAttrPath = systemVar.path;

  const [infoAttrRes, globalAttrRes, systemAttrRes] = await Promise.all([
    readAttrFile(join(commonGitDir, "info", "attributes")),
    globalAttrPath ? readAttrFile(globalAttrPath) : Promise.resolve({ ok: true as const, text: null }),
    systemAttrPath ? readAttrFile(systemAttrPath) : Promise.resolve({ ok: true as const, text: null }),
  ]);
  if (!infoAttrRes.ok || !globalAttrRes.ok || !systemAttrRes.ok) return { ok: false };
  if (
    hasConfiguredFilterRule(infoAttrRes.text, configuredDrivers) ||
    hasConfiguredFilterRule(globalAttrRes.text, configuredDrivers) ||
    hasConfiguredFilterRule(systemAttrRes.text, configuredDrivers)
  ) {
    return { ok: false };
  }

  const lsTreeRes = await execGit(repo, ["ls-tree", "-r", "-z", commitOid], { env: { GIT_NO_LAZY_FETCH: "1" } });
  if (lsTreeRes.code !== 0) return { ok: false };
  const hookLow = hookCheck.inTreeHookPath !== null ? hookCheck.inTreeHookPath.toLowerCase() : null;
  const attrBlobs = new Set<string>();
  const rawTree = lsTreeRes.stdout.toString("utf8");
  for (const record of rawTree.split("\0")) {
    if (record === "") continue;
    if (record.startsWith("160000 ")) return { ok: false };
    const tab = record.indexOf("\t");
    if (tab < 0) continue;
    const pathPart = record.slice(tab + 1);
    if (hookLow !== null) {
      const pLow = pathPart.toLowerCase();
      if (pLow === hookLow) {
        return { ok: false };
      }
      // Tracked symlink (`120000`) on any prefix of `core.hooksPath` (e.g. `hooks -> scripts`).
      if (record.startsWith("120000 ") && hookLow.startsWith(`${pLow}/`)) {
        return { ok: false };
      }
    }
    if (configuredDrivers.size > 0) {
      const slash = pathPart.lastIndexOf("/");
      const base = slash >= 0 ? pathPart.slice(slash + 1) : pathPart;
      if (base === ".gitattributes") {
        const header = record.slice(0, tab).split(" ");
        const blobOid = header[2];
        if (blobOid && HEX40_RE.test(blobOid)) attrBlobs.add(blobOid);
      }
    }
  }
  for (const blobOid of attrBlobs) {
    const blobRes = await execGit(repo, ["cat-file", "blob", blobOid], { env: { GIT_NO_LAZY_FETCH: "1" } });
    if (blobRes.code !== 0) return { ok: false };
    if (hasConfiguredFilterRule(blobRes.stdout.toString("utf8"), configuredDrivers)) return { ok: false };
  }

  const [autocrlf, eol, symlinks, filemode] = await Promise.all([
    gitConfigGet(repo, "core.autocrlf"),
    gitConfigGet(repo, "core.eol"),
    gitConfigGet(repo, "core.symlinks"),
    gitConfigGet(repo, "core.filemode"),
  ]);
  if (!autocrlf.ok || !eol.ok || !symlinks.ok || !filemode.ok) return { ok: false };

  const checkoutFingerprint = createHash("sha256")
    .update(
      JSON.stringify({
        autocrlf: autocrlf.value,
        eol: eol.value,
        symlinks: symlinks.value,
        filemode: filemode.value,
        infoAttr: infoAttrRes.text,
        globalAttrPath,
        globalAttr: globalAttrRes.text,
        systemAttrPath,
        systemAttr: systemAttrRes.text,
        filterConfig: filterConfigRaw,
      }),
    )
    .digest("hex");

  return { ok: true, commonGitDir, commitOid, checkoutFingerprint };
}

type GenCandidate = { dirName: string; oid: string; checkoutFingerprint: string; mtimeMs: number };

const HEX64_RE = /^[0-9a-f]{64}$/;

async function validateGeneration(cowDir: string, name: string): Promise<GenCandidate | null> {
  if (!GEN_KEY_RE.test(name)) return null;
  const genPath = join(cowDir, name);
  const [treeSt, idxSt, metaSt, metaText] = await Promise.all([
    stat(join(genPath, "tree")).catch(() => null),
    stat(join(genPath, "index")).catch(() => null),
    stat(join(genPath, "meta.json")).catch(() => null),
    readFile(join(genPath, "meta.json"), "utf8").catch(() => null),
  ]);
  if (!treeSt?.isDirectory() || !idxSt?.isFile() || metaSt === null || metaText === null) return null;
  try {
    const meta = JSON.parse(metaText) as { commit?: unknown; checkoutFingerprint?: unknown };
    if (typeof meta.commit !== "string" || !HEX40_RE.test(meta.commit)) return null;
    if (typeof meta.checkoutFingerprint !== "string" || !HEX64_RE.test(meta.checkoutFingerprint)) return null;
    if (makeGenKey(meta.commit, meta.checkoutFingerprint) !== name) return null;
    return {
      dirName: name,
      oid: meta.commit,
      checkoutFingerprint: meta.checkoutFingerprint,
      mtimeMs: metaSt.mtimeMs,
    };
  } catch {
    return null;
  }
}

async function listMatchingGenerations(cowDir: string, checkoutFingerprint: string): Promise<GenCandidate[]> {
  const names = await readdir(cowDir).catch(() => [] as string[]);
  const out: GenCandidate[] = [];
  for (const name of names) {
    if (name.startsWith(".")) continue;
    const cand = await validateGeneration(cowDir, name);
    if (cand !== null && cand.checkoutFingerprint === checkoutFingerprint) {
      out.push(cand);
    }
  }
  return out;
}

async function diffTouchesGitattributes(repo: string, genOid: string, commitOid: string): Promise<boolean> {
  const res = await execGit(repo, ["diff-tree", "-r", "-z", "--name-only", genOid, commitOid], {
    env: { GIT_NO_LAZY_FETCH: "1" },
  });
  if (res.code !== 0) return true;
  for (const rel of res.stdout.toString("utf8").split("\0")) {
    if (rel === "") continue;
    const slash = rel.lastIndexOf("/");
    const base = slash >= 0 ? rel.slice(slash + 1) : rel;
    if (base === ".gitattributes") return true;
  }
  return false;
}

async function defaultBaseCommit(repo: string): Promise<string | null> {
  const originHead = await execGit(repo, ["rev-parse", "--verify", "origin/HEAD^{commit}"], {
    env: { GIT_NO_LAZY_FETCH: "1" },
  });
  if (originHead.code === 0) {
    const oid = originHead.stdout.toString("utf8").trim();
    if (HEX40_RE.test(oid)) return oid;
  }
  const head = await execGit(repo, ["rev-parse", "--verify", "HEAD^{commit}"], {
    env: { GIT_NO_LAZY_FETCH: "1" },
  });
  if (head.code === 0) {
    const oid = head.stdout.toString("utf8").trim();
    if (HEX40_RE.test(oid)) return oid;
  }
  return null;
}

async function clearWorktreeExceptGit(absPath: string): Promise<void> {
  const names = await readdir(absPath).catch(() => [] as string[]);
  for (const name of names) {
    if (name === ".git") continue;
    await removeTree(join(absPath, name), { force: true }).catch(() => {});
  }
}

async function stripSkipWorktreeBits(absPath: string, tmpIndex: string): Promise<boolean> {
  const lsRes = await execGit(absPath, ["-c", "core.sparseCheckout=false", "-c", "index.sparse=false", "ls-files", "-t", "-z"], {
    env: { GIT_INDEX_FILE: tmpIndex },
  });
  if (lsRes.code !== 0) return false;

  const skipPaths: Buffer[] = [];
  const buf = lsRes.stdout;
  let start = 0;
  for (let i = 0; i <= buf.length; i++) {
    if (i < buf.length && buf[i] !== 0) continue;
    if (i > start) {
      const entry = buf.subarray(start, i);
      if (entry.length < 3 || entry[1] !== 0x20) return false;
      const pathBuf = entry.subarray(2);
      // Reject sparse directory entries (`index.sparse`) ending with '/'.
      if (pathBuf[pathBuf.length - 1] === 0x2f) return false;
      if (entry[0] === 0x53) {
        skipPaths.push(pathBuf);
      }
    }
    start = i + 1;
  }

  if (skipPaths.length === 0) return true;

  const nul = Buffer.from([0]);
  const stdinBuf = Buffer.concat(skipPaths.flatMap((p) => [p, nul]));
  const updRes = await execGit(
    absPath,
    ["-c", "core.sparseCheckout=false", "-c", "index.sparse=false", "update-index", "--no-skip-worktree", "-z", "--stdin"],
    { env: { GIT_INDEX_FILE: tmpIndex }, input: stdinBuf },
  );
  return updRes.code === 0 && !updRes.stdinError;
}

function makeGenKey(commitOid: string, checkoutFingerprint: string): string {
  return `${commitOid}-${checkoutFingerprint.slice(0, 16)}`;
}

async function promoteGeneration(
  cowDir: string,
  absPath: string,
  wtGitDir: string,
  commitOid: string,
  checkoutFingerprint: string,
): Promise<boolean> {
  await mkdir(cowDir, { recursive: true });
  const tmp = join(cowDir, `.tmp-${process.pid}-${randomBytes(6).toString("hex")}`);
  let promoted = false;
  try {
    await mkdir(tmp, { recursive: true });
    await cloneTree(absPath, join(tmp, "tree"));
    await rm(join(tmp, "tree", ".git"), { force: true, recursive: true });
    await copyFile(join(wtGitDir, "index"), join(tmp, "index"));
    const stripped = await stripSkipWorktreeBits(absPath, join(tmp, "index"));
    if (!stripped) {
      await removeTree(tmp, { force: true }).catch(() => {});
      return false;
    }
    await writeFile(join(tmp, "meta.json"), `${JSON.stringify({ commit: commitOid, checkoutFingerprint })}\n`);
    const target = join(cowDir, makeGenKey(commitOid, checkoutFingerprint));
    // Immutable generation directory: never delete an existing target (eliminates reader race).
    try {
      await rename(tmp, target);
      promoted = true;
    } catch (error) {
      const code = (error as NodeJS.ErrnoException).code;
      if (code === "EEXIST" || code === "ENOTEMPTY" || code === "EISDIR") {
        await removeTree(tmp, { force: true }).catch(() => {});
      } else {
        throw error;
      }
    }
  } catch {
    await removeTree(tmp, { force: true }).catch(() => {});
  }
  return promoted;
}

async function cleanupCowDir(cowDir: string, keepPreferKey?: string): Promise<void> {
  const names = await readdir(cowDir).catch(() => [] as string[]);
  const now = wall.now();
  const gens: { name: string; mtimeMs: number }[] = [];

  for (const name of names) {
    const full = join(cowDir, name);
    if (name.startsWith(".tmp-")) {
      const st = await lstat(full).catch(() => null);
      if (st !== null && now - st.mtimeMs > TMP_EXPIRE_MS) {
        await removeTree(full, { force: true }).catch(() => {});
      }
      continue;
    }
    if (name.startsWith(".")) continue;
    if (GEN_KEY_RE.test(name)) {
      const cand = await validateGeneration(cowDir, name);
      if (cand === null) {
        const st = await lstat(full).catch(() => null);
        if (st !== null && now - st.mtimeMs > TMP_EXPIRE_MS) {
          await removeTree(full, { force: true }).catch(() => {});
        }
        continue;
      }
      gens.push({ name, mtimeMs: cand.mtimeMs });
    } else if (HEX40_RE.test(name)) {
      const st = await lstat(full).catch(() => null);
      if (st !== null && now - st.mtimeMs > TMP_EXPIRE_MS) {
        await removeTree(full, { force: true }).catch(() => {});
      }
    }
  }

  gens.sort((a, b) => {
    if (b.mtimeMs !== a.mtimeMs) return b.mtimeMs - a.mtimeMs;
    if (keepPreferKey) {
      if (a.name === keepPreferKey) return -1;
      if (b.name === keepPreferKey) return 1;
    }
    return a.name.localeCompare(b.name);
  });

  for (const old of gens.slice(KEEP_GENERATIONS)) {
    await removeTree(join(cowDir, old.name), { force: true }).catch(() => {});
  }
}

/// Core CoW worktree creation entry point, returning structured metadata for tests and CLI.
export async function runWorktreeCow(argv: readonly string[], callerCwd: string): Promise<WorktreeCowResult> {
  const { repo, worktreeArgs, fastPath } = parseWorktreeArgs(argv, callerCwd);
  if (fastPath === null) {
    const code = await passthroughGit(repo, worktreeArgs, callerCwd);
    return { code, usedCow: false, promoted: false, hitGen: null };
  }

  const { absPath, commitish } = fastPath;
  const pre = await runPreflight(repo, absPath, commitish).catch(() => ({ ok: false as const }));
  if (!pre.ok) {
    const code = await passthroughGit(repo, worktreeArgs, callerCwd);
    return { code, usedCow: false, promoted: false, hitGen: null };
  }

  const { commonGitDir, commitOid, checkoutFingerprint } = pre;
  const cowDir = join(commonGitDir, "cow");
  const candidates = await listMatchingGenerations(cowDir, checkoutFingerprint);

  let selectedGen: GenCandidate | null = null;
  const exact = candidates.find((c) => c.oid === commitOid);
  if (exact) {
    selectedGen = exact;
  } else if (candidates.length > 0) {
    candidates.sort((a, b) => b.mtimeMs - a.mtimeMs);
    const newest = candidates[0]!;
    if (!(await diffTouchesGitattributes(repo, newest.oid, commitOid))) {
      selectedGen = newest;
    }
  }

  // Step A: register detached worktree without checkout.
  const addRes = await execGit(repo, ["worktree", "add", "--no-checkout", "--detach", absPath, commitOid]);
  if (addRes.code !== 0) {
    if (addRes.stdout.length > 0) process.stdout.write(addRes.stdout);
    if (addRes.stderr.length > 0) process.stderr.write(addRes.stderr);
    return { code: addRes.code, usedCow: true, promoted: false, hitGen: null };
  }

  const gitDirRes = await execGit(absPath, ["rev-parse", "--absolute-git-dir"]);
  if (gitDirRes.code !== 0) {
    await execGit(repo, ["worktree", "remove", "--force", absPath]).catch(() => {});
    if (gitDirRes.stderr.length > 0) process.stderr.write(gitDirRes.stderr);
    return { code: gitDirRes.code, usedCow: true, promoted: false, hitGen: null };
  }
  const wtGitDir = gitDirRes.stdout.toString("utf8").trim();

  // Step B: populate working tree and index from matched CoW generation.
  let hitGen: string | null = null;
  if (selectedGen !== null) {
    try {
      await cloneTree(join(cowDir, selectedGen.dirName, "tree"), absPath);
      await copyFile(join(cowDir, selectedGen.dirName, "index"), join(wtGitDir, "index"));
      const refreshRes = await execGit(absPath, ["update-index", "-q", "--refresh"]);
      if (refreshRes.code !== 0 && refreshRes.code !== 1) {
        throw new Error(`git update-index --refresh exited with ${refreshRes.code}`);
      }
      hitGen = selectedGen.oid;
    } catch {
      await clearWorktreeExceptGit(absPath);
      await rm(join(wtGitDir, "index"), { force: true }).catch(() => {});
      hitGen = null;
    }
  }

  // Step C: always finalize working tree and index against target commit (handles diffs and sparse checkout).
  const resetRes = await execGit(absPath, ["reset", "--hard", "-q"]);
  if (resetRes.code !== 0) {
    await execGit(repo, ["worktree", "remove", "--force", absPath]).catch(() => {});
    if (resetRes.stdout.length > 0) process.stdout.write(resetRes.stdout);
    if (resetRes.stderr.length > 0) process.stderr.write(resetRes.stderr);
    return { code: resetRes.code, usedCow: true, promoted: false, hitGen };
  }

  // Step D: opportunistic lockless promotion (best-effort; never fails the command).
  let promoted = false;
  try {
    const hasValidExact = candidates.some((c) => c.oid === commitOid);
    let shouldPromote = candidates.length === 0;
    if (!shouldPromote && !hasValidExact) {
      const baseOid = await defaultBaseCommit(repo);
      if (baseOid === commitOid) shouldPromote = true;
    }
    if (shouldPromote && !hasValidExact) {
      promoted = await promoteGeneration(cowDir, absPath, wtGitDir, commitOid, checkoutFingerprint);
    }
    await cleanupCowDir(cowDir, promoted ? makeGenKey(commitOid, checkoutFingerprint) : undefined);
  } catch {
    // Best-effort only.
  }

  if (addRes.stderr.length > 0) process.stderr.write(addRes.stderr);
  return { code: 0, usedCow: true, promoted, hitGen };
}

/// CLI entrypoint called from `station/src/main.ts` (`stillfail worktree ...`).
export async function worktreeCommand(argv: readonly string[], callerCwd: string): Promise<number> {
  const res = await runWorktreeCow(argv, callerCwd);
  return res.code;
}
