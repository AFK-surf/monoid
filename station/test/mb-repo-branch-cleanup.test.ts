// End-to-end tests for MoonBit station PR B (`stillfail-reader run`):
// P53Upkeep::prune_all_repo_branches, p53_prune_expired_repo_bundles, and relaxed P53Upkeep::relieve_repos.
import assert from "node:assert/strict";
import { type ChildProcess, execFileSync, spawn } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, symlinkSync, utimesSync, writeFileSync } from "node:fs";
import { request } from "node:http";
import { createServer, type Server } from "node:net";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { createInterface } from "node:readline";
import { after, test } from "node:test";
import { mbStationBinary } from "./mb-harness.ts";

const binary = mbStationBinary();
const skip = binary === null ? "the MoonBit program (stillfail-reader) is not built here" : process.platform === "win32" ? "the launcher's descriptors are Unix's" : false;

const HOUR = 3_600_000;
const DAY = 24 * HOUR;

const dirs: string[] = [];
const fresh = (what: string) => {
  const dir = mkdtempSync(join(process.platform === "darwin" ? "/tmp" : tmpdir(), `mb-reclaim-b-${what}-`));
  dirs.push(dir);
  return dir;
};
const children: ChildProcess[] = [];
after(async () => {
  const left = children.filter((c) => c.exitCode === null && c.signalCode === null);
  for (const c of left) c.kill("SIGKILL");
  await Promise.race([
    Promise.all(left.map((c) => (c.exitCode === null && c.signalCode === null ? new Promise<void>((r) => c.once("exit", () => r())) : undefined))),
    new Promise((r) => setTimeout(r, 5_000).unref()),
  ]);
  for (const d of dirs) rmSync(d, { recursive: true, force: true });
});

function git(cwd: string, args: string[], extraEnv: Record<string, string> = {}): string {
  return execFileSync("git", args, {
    cwd,
    encoding: "utf8",
    env: {
      ...process.env,
      GIT_AUTHOR_NAME: "Test",
      GIT_AUTHOR_EMAIL: "test@example.com",
      GIT_COMMITTER_NAME: "Test",
      GIT_COMMITTER_EMAIL: "test@example.com",
      GIT_TERMINAL_PROMPT: "0",
      ...extraEnv,
    },
  }).trim();
}

function isoSec(ms: number): string {
  return `${Math.floor(ms / 1000)} +0000`;
}

function setMtime(path: string, ms: number): void {
  const sec = ms / 1000;
  utimesSync(path, sec, sec);
}

function setRepoMtime(repo: string, ms: number): void {
  for (const rel of [".git/HEAD", ".git/FETCH_HEAD", ".git/index", ".git/logs/HEAD"]) {
    const p = join(repo, rel);
    if (existsSync(p)) setMtime(p, ms);
  }
}

function ageBranchRef(repo: string, branch: string, ms: number): void {
  rmSync(join(repo, ".git", "logs", "refs", "heads", branch), { force: true });
  const refFile = join(repo, ".git", "refs", "heads", branch);
  if (existsSync(refFile)) setMtime(refFile, ms);
}

function branchExists(repo: string, branch: string): boolean {
  try {
    git(repo, ["show-ref", "--verify", "--quiet", `refs/heads/${branch}`]);
    return true;
  } catch {
    return false;
  }
}

function initClone(cloneDir: string, bareDir: string, baseNow: number): string {
  mkdirSync(bareDir, { recursive: true });
  git(bareDir, ["init", "--bare", "-b", "main"]);
  mkdirSync(cloneDir, { recursive: true });
  git(cloneDir, ["init", "-b", "main"]);
  writeFileSync(join(cloneDir, "README.md"), "hello\n");
  git(cloneDir, ["add", "README.md"]);
  git(cloneDir, ["commit", "-m", "init"], {
    GIT_AUTHOR_DATE: isoSec(baseNow - 30 * DAY),
    GIT_COMMITTER_DATE: isoSec(baseNow - 30 * DAY),
  });
  git(cloneDir, ["remote", "add", "origin", bareDir]);
  git(cloneDir, ["push", "-u", "origin", "main"]);
  git(cloneDir, ["remote", "set-head", "origin", "main"]);
  return cloneDir;
}

function withoutFront(): NodeJS.ProcessEnv {
  const env = { ...process.env };
  delete env.STILLFAIL_MESH_FRONT;
  return env;
}

async function launch(data: string, app: string) {
  const listener = () => new Promise<Server>((resolve) => {
    const s = createServer();
    s.listen(0, "127.0.0.1", () => resolve(s));
  });
  const [mcp, loop] = [await listener(), await listener()];
  const fd = (s: Server) => (s as any)._handle.fd as number;
  const child = spawn(binary!, ["run", "--app", app, "--data", data, "--launcher-fds", "3,4,5", "--launcher-carries", "--launcher-heartbeat"], {
    stdio: ["ignore", "pipe", "pipe", fd(mcp), fd(loop), "pipe"],
    env: { ...withoutFront(), STILLFAIL_PARTS_DOOR: "1", STILLFAIL_LOCAL_ADMIN: "1", STILLFAIL_NO_DISCOVERY: "1" },
  });
  children.push(child);
  mcp.close();
  loop.close();
  const said: any[] = [];
  const waiters: (() => void)[] = [];
  createInterface({ input: (child.stdio as readonly unknown[])[5] as import("node:net").Socket }).on("line", (line) => {
    said.push(JSON.parse(line));
    for (const w of waiters.splice(0)) w();
  });
  let err = "";
  child.stderr!.on("data", (d) => (err += d));
  const next = (what: string, ok: (m: any) => boolean) =>
    new Promise<any>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`never said: ${what}; said ${JSON.stringify(said)}; stderr ${err}`)), 20_000);
      const look = () => {
        const found = said.find(ok);
        if (found !== undefined) {
          clearTimeout(timer);
          resolve(found);
        } else waiters.push(look);
      };
      look();
    });
  const tell = (m: unknown) => (child.stdio as readonly unknown[])[5] && ((child.stdio as any)[5] as import("node:net").Socket).write(JSON.stringify(m) + "\n");
  const ended = new Promise<number | null>((resolve) => child.once("exit", (c) => resolve(c)));
  return { child, next, tell, ended, err: () => err };
}

function httpJson(port: number, method: string, path: string, body?: unknown): Promise<{ status: number; body: any }> {
  return new Promise((resolve, reject) => {
    const data = body === undefined ? null : JSON.stringify(body);
    const req = request({
      host: "127.0.0.1",
      port,
      method,
      path,
      headers: data === null ? {} : { "content-type": "application/json", "content-length": Buffer.byteLength(data) },
    }, (res) => {
      let text = "";
      res.setEncoding("utf8");
      res.on("data", (d) => (text += d));
      res.on("end", () => {
        let parsed: any = text;
        try { parsed = JSON.parse(text); } catch {}
        resolve({ status: res.statusCode ?? 0, body: parsed });
      });
    });
    req.on("error", reject);
    if (data !== null) req.write(data);
    req.end();
  });
}

test("MoonBit station prunes shared-clone branches (with 14d bundling), expires 30d bundles, and runs relaxed relieve_repos", { skip }, async () => {
  const data = fresh("data");
  const app = fresh("app");
  const remotes = fresh("remotes");
  const outside = fresh("outside");
  mkdirSync(join(data, "repos"), { recursive: true });
  mkdirSync(join(data, "sessions", "cl"), { recursive: true });
  mkdirSync(join(data, "homes", "cc"), { recursive: true });
  mkdirSync(join(data, "mesh"), { recursive: true });
  writeFileSync(join(data, "mesh", "cloud.json"), JSON.stringify({
    origin: "http://127.0.0.1:1",
    workspace: "ws-1",
    station: "st-1",
    name: "mb-reclaim-b",
    memberships: [{ workspace: "ws-1", home: true }],
  }));
  writeFileSync(join(data, "config.json"), JSON.stringify({
    profiles: [{ id: "cc", name: "CC", runtime: "claude", runtimes: ["claude"], home: join(data, "homes", "cc") }],
    connects: [{ id: "cl", kind: "slack", mode: "multi-session", bind: { runtime: "claude", profile: "cc" } }],
  }));

  const now = Date.now();

  // ── Repo 1: branch cleanup showcase ──
  const repo = initClone(join(data, "repos", "demo"), join(remotes, "demo.git"), now);

  // Symlinked external repo -> untouched
  const extRepo = initClone(join(outside, "ext"), join(remotes, "ext.git"), now);
  git(extRepo, ["branch", "ext-a", "main"]);
  ageBranchRef(extRepo, "ext-a", now - 2 * DAY);
  symlinkSync(extRepo, join(data, "repos", "linked-ext"));

  // (a) on remote
  git(repo, ["checkout", "-b", "a-remote", "main"]);
  writeFileSync(join(repo, "a.txt"), "a\n");
  git(repo, ["add", "a.txt"]);
  git(repo, ["commit", "-m", "a"], { GIT_AUTHOR_DATE: isoSec(now - 5 * DAY), GIT_COMMITTER_DATE: isoSec(now - 5 * DAY) });
  git(repo, ["push", "origin", "a-remote"]);
  git(repo, ["checkout", "main"]);
  ageBranchRef(repo, "a-remote", now - 2 * DAY);

  // (b) cherry-picked
  git(repo, ["checkout", "-b", "b-cherry", "main"]);
  writeFileSync(join(repo, "ch.txt"), "ch\n");
  git(repo, ["add", "ch.txt"]);
  git(repo, ["commit", "-m", "ch"], { GIT_AUTHOR_DATE: isoSec(now - 5 * DAY), GIT_COMMITTER_DATE: isoSec(now - 5 * DAY) });
  const chSha = git(repo, ["rev-parse", "HEAD"]);
  git(repo, ["checkout", "main"]);
  git(repo, ["cherry-pick", chSha]);
  git(repo, ["push", "origin", "main"]);
  ageBranchRef(repo, "b-cherry", now - 2 * DAY);

  // (c) squash-merged (2 commits squashed into 1 so git cherry sees '+' and merge-tree catches it)
  git(repo, ["checkout", "-b", "c-squash", "main"]);
  writeFileSync(join(repo, "sq1.txt"), "sq1\n");
  git(repo, ["add", "sq1.txt"]);
  git(repo, ["commit", "-m", "sq1"], { GIT_AUTHOR_DATE: isoSec(now - 5 * DAY), GIT_COMMITTER_DATE: isoSec(now - 5 * DAY) });
  writeFileSync(join(repo, "sq2.txt"), "sq2\n");
  git(repo, ["add", "sq2.txt"]);
  git(repo, ["commit", "-m", "sq2"], { GIT_AUTHOR_DATE: isoSec(now - 5 * DAY), GIT_COMMITTER_DATE: isoSec(now - 5 * DAY) });
  git(repo, ["checkout", "main"]);
  git(repo, ["merge", "--squash", "c-squash"]);
  git(repo, ["commit", "-m", "squash c"], { GIT_AUTHOR_DATE: isoSec(now - 4 * DAY), GIT_COMMITTER_DATE: isoSec(now - 4 * DAY) });
  git(repo, ["push", "origin", "main"]);
  ageBranchRef(repo, "c-squash", now - 2 * DAY);

  // (d) process-only + empty
  git(repo, ["checkout", "-b", "d-proc", "main"]);
  mkdirSync(join(repo, "scratch"), { recursive: true });
  writeFileSync(join(repo, "scratch", "x.md"), "x\n");
  writeFileSync(join(repo, "HANDOFF.md"), "h\n");
  git(repo, ["add", "scratch/x.md", "HANDOFF.md"]);
  git(repo, ["commit", "-m", "proc"], { GIT_AUTHOR_DATE: isoSec(now - 3 * DAY), GIT_COMMITTER_DATE: isoSec(now - 3 * DAY) });
  git(repo, ["checkout", "main"]);
  ageBranchRef(repo, "d-proc", now - 2 * DAY);

  git(repo, ["checkout", "-b", "d-empty", "main"]);
  git(repo, ["commit", "--allow-empty", "-m", "empty"], { GIT_AUTHOR_DATE: isoSec(now - 3 * DAY), GIT_COMMITTER_DATE: isoSec(now - 3 * DAY) });
  git(repo, ["checkout", "main"]);
  ageBranchRef(repo, "d-empty", now - 2 * DAY);

  // (7) 15d stale unpushed
  git(repo, ["checkout", "-b", "stale-15d", "main"]);
  writeFileSync(join(repo, "stale.ts"), "export const s = 15;\n");
  git(repo, ["add", "stale.ts"]);
  git(repo, ["commit", "-m", "stale"], { GIT_AUTHOR_DATE: isoSec(now - 15 * DAY), GIT_COMMITTER_DATE: isoSec(now - 15 * DAY) });
  const staleSha = git(repo, ["rev-parse", "HEAD"]);
  git(repo, ["checkout", "main"]);
  ageBranchRef(repo, "stale-15d", now - 15 * DAY);

  // Preserved: locked missing worktree, <24h fresh, 13d unpushed, 15d diverged remote
  const lockedWt = join(data, "sessions", "cl", "locked", "workspace", "wt-l");
  mkdirSync(dirname(lockedWt), { recursive: true });
  git(repo, ["worktree", "add", "-b", "keep-locked", lockedWt, "main"]);
  rmSync(lockedWt, { recursive: true, force: true });
  writeFileSync(join(repo, ".git", "worktrees", "wt-l", "locked"), "archived\n");
  ageBranchRef(repo, "keep-locked", now - 10 * DAY);

  // Too fresh (<24h) class-a branch (keeps its real fresh reflog at `now`)
  git(repo, ["branch", "keep-fresh", "main"]);

  git(repo, ["checkout", "-b", "keep-13d", "main"]);
  writeFileSync(join(repo, "k13.ts"), "export const k = 13;\n");
  git(repo, ["add", "k13.ts"]);
  git(repo, ["commit", "-m", "k13"], { GIT_AUTHOR_DATE: isoSec(now - 13 * DAY), GIT_COMMITTER_DATE: isoSec(now - 13 * DAY) });
  git(repo, ["checkout", "main"]);
  ageBranchRef(repo, "keep-13d", now - 13 * DAY);

  git(repo, ["checkout", "-b", "keep-div", "main"]);
  writeFileSync(join(repo, "div.ts"), "r\n");
  git(repo, ["add", "div.ts"]);
  git(repo, ["commit", "-m", "div r"], { GIT_AUTHOR_DATE: isoSec(now - 16 * DAY), GIT_COMMITTER_DATE: isoSec(now - 16 * DAY) });
  git(repo, ["push", "origin", "keep-div"]);
  writeFileSync(join(repo, "div.ts"), "l\n");
  git(repo, ["add", "div.ts"]);
  git(repo, ["commit", "-m", "div l"], { GIT_AUTHOR_DATE: isoSec(now - 15 * DAY), GIT_COMMITTER_DATE: isoSec(now - 15 * DAY) });
  git(repo, ["checkout", "main"]);
  ageBranchRef(repo, "keep-div", now - 15 * DAY);

  // ── Bundle expiry setup (31d old vs 29d fresh) ──
  const oldBDir = join(data, "repo-bundles", "expired-clone");
  const keepBDir = join(data, "repo-bundles", "fresh-clone");
  mkdirSync(oldBDir, { recursive: true });
  mkdirSync(keepBDir, { recursive: true });
  const oldB = join(oldBDir, "2026-10-01T00-00-00Z.bundle");
  const oldT = join(oldBDir, "2026-10-01T00-00-00Z.txt");
  const keepB = join(keepBDir, "2026-11-01T00-00-00Z.bundle");
  writeFileSync(oldB, "old");
  writeFileSync(oldT, "old");
  writeFileSync(keepB, "keep");
  setMtime(oldB, now - 31 * DAY);
  setMtime(oldT, now - 31 * DAY);
  setMtime(keepB, now - 29 * DAY);

  // ── Relaxed relieve_repos candidates ──
  const procUntracked = initClone(join(data, "repos", "proc-untracked"), join(remotes, "pu.git"), now);
  mkdirSync(join(procUntracked, "scratch"), { recursive: true });
  writeFileSync(join(procUntracked, "scratch", "notes.md"), "tmp\n");
  git(procUntracked, ["remote", "set-url", "origin", "https://github.com/example/pu.git"]);
  setRepoMtime(procUntracked, now - 4 * DAY);

  const realUntracked = initClone(join(data, "repos", "real-untracked"), join(remotes, "ru.git"), now);
  mkdirSync(join(realUntracked, "src"), { recursive: true });
  writeFileSync(join(realUntracked, "src", "new.ts"), "export const x = 1;\n");
  git(realUntracked, ["remote", "set-url", "origin", "https://github.com/example/ru.git"]);
  setRepoMtime(realUntracked, now - 4 * DAY);

    const idle2d = initClone(join(data, "repos", "idle-2d"), join(remotes, "i2.git"), now);
    git(idle2d, ["remote", "set-url", "origin", "https://github.com/example/i2.git"]);
    setRepoMtime(idle2d, now - 2 * DAY);

    const unpushedTag = initClone(join(data, "repos", "unpushed-tag"), join(remotes, "utag.git"), now);
    git(unpushedTag, ["checkout", "--detach", "HEAD"]);
    writeFileSync(join(unpushedTag, "tag.ts"), "export const t = 1;\n");
    git(unpushedTag, ["add", "tag.ts"]);
    git(unpushedTag, ["commit", "-m", "tagged commit"], { GIT_AUTHOR_DATE: isoSec(now - 20 * DAY), GIT_COMMITTER_DATE: isoSec(now - 20 * DAY) });
    git(unpushedTag, ["tag", "v0.1-local"]);
    git(unpushedTag, ["checkout", "main"]);
    git(unpushedTag, ["remote", "set-url", "origin", "https://github.com/example/utag.git"]);
    setRepoMtime(unpushedTag, now - 4 * DAY);

  const launched = await launch(data, app);
  try {
    const served = await launched.next("mcp serving", (m) => m.serving === "mcp");
    const port = served.port as number;

    // 1. Prune repo branches
    const pb = await httpJson(port, "POST", "/parts/ask/upkeep.pruneRepoBranches", [now]);
    assert.equal(pb.status, 200, JSON.stringify(pb));
    const demoSummary = (pb.body as any[]).find((x) => x.repo === "demo");
    assert.ok(demoSummary, JSON.stringify(pb.body));
    assert.equal(demoSummary.deletedRemote, 1);
    assert.equal(demoSummary.deletedCherry, 1);
    assert.equal(demoSummary.deletedMerged, 2); // c-squash + d-empty
    assert.equal(demoSummary.deletedProcessOnly, 1);
    assert.equal(demoSummary.deletedStaleBundled, 1);
    assert.ok(demoSummary.bundlePath && existsSync(demoSummary.bundlePath));

    for (const gone of ["a-remote", "b-cherry", "c-squash", "d-proc", "d-empty", "stale-15d"]) {
      assert.equal(branchExists(repo, gone), false, `MoonBit deleted: ${gone}`);
    }
    for (const kept of ["main", "keep-locked", "keep-fresh", "keep-13d", "keep-div"]) {
      assert.equal(branchExists(repo, kept), true, `MoonBit preserved: ${kept}`);
    }
    assert.equal(branchExists(extRepo, "ext-a"), true, "MoonBit untouched symlinked ext repo");

    // Verify bundle + manifest + restore
    git(repo, ["bundle", "verify", demoSummary.bundlePath]);
    const txtPath = (demoSummary.bundlePath as string).replace(/\.bundle$/, ".txt");
    assert.ok(readFileSync(txtPath, "utf8").includes(`stale-15d ${staleSha}`));
    git(repo, ["fetch", demoSummary.bundlePath, "refs/heads/*:refs/heads/*"]);
    assert.equal(git(repo, ["rev-parse", "refs/heads/stale-15d"]), staleSha);

    // 2. Expire 30d bundles
    const exp = await httpJson(port, "POST", "/parts/ask/upkeep.pruneExpiredRepoBundles", [now]);
    assert.equal(exp.status, 200, JSON.stringify(exp));
    assert.ok(!existsSync(oldB) && !existsSync(oldT) && !existsSync(oldBDir), "31d bundles & empty dir removed");
    assert.ok(existsSync(keepB), "29d bundle preserved");

    // 3. Relaxed relieve_repos (create idle-4d-stale AFTER step 1 so relieve_repos itself bundles & prunes stale-rel)
    const idle4dStale = initClone(join(data, "repos", "idle-4d-stale"), join(remotes, "i4s.git"), now);
    git(idle4dStale, ["checkout", "-b", "stale-rel", "main"]);
    writeFileSync(join(idle4dStale, "r.ts"), "export const r = 1;\n");
    git(idle4dStale, ["add", "r.ts"]);
    git(idle4dStale, ["commit", "-m", "stale rel"], { GIT_AUTHOR_DATE: isoSec(now - 15 * DAY), GIT_COMMITTER_DATE: isoSec(now - 15 * DAY) });
    git(idle4dStale, ["checkout", "main"]);
    ageBranchRef(idle4dStale, "stale-rel", now - 15 * DAY);
    git(idle4dStale, ["remote", "set-url", "origin", "https://github.com/example/i4s.git"]);
    setRepoMtime(idle4dStale, now - 4 * DAY);

    const rel = await httpJson(port, "POST", "/parts/ask/upkeep.relieveRepos", [now, 1e18]);
    assert.equal(rel.status, 200, JSON.stringify(rel));
    assert.deepEqual((rel.body as string[]).sort(), ["idle-4d-stale", "proc-untracked"]);
    assert.ok(!existsSync(procUntracked), "process-only untracked clone reclaimed");
    assert.ok(!existsSync(idle4dStale), "4d idle clone with 15d stale branch reclaimed after bundling");
    assert.ok(existsSync(realUntracked), "non-process untracked clone preserved");
    assert.ok(existsSync(idle2d), "2d idle clone preserved");
    assert.ok(existsSync(unpushedTag), "unpushed local tag clone preserved");
    assert.ok(existsSync(join(data, "repo-bundles", "idle-4d-stale")), "stale branch bundled before clone deletion");

    // told to stop (`op`, the launcher's control channel), it winds down with its processes (`--builder replica-export`)
    launched.tell({ op: "stop" });
    assert.equal(await launched.ended, 0, launched.err());
  } finally {
    if (launched.child.exitCode === null && launched.child.signalCode === null) {
      launched.tell({ op: "stop" });
      await Promise.race([launched.ended, new Promise((r) => setTimeout(r, 3_000).unref())]);
    }
  }
});
