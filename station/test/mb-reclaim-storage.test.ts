// End-to-end tests for the MoonBit station's storage reclamation (stillfail-reader run):
// p53_prune_repo_worktrees, P53Upkeep::relieve_repos, Hub::delete_session (transcripts.exclusive + fs.rmRoom).
import assert from "node:assert/strict";
import { type ChildProcess, execFileSync, spawn } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, realpathSync, rmSync, symlinkSync, utimesSync, writeFileSync } from "node:fs";
import { request } from "node:http";
import { createServer, type Server } from "node:net";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { createInterface } from "node:readline";
import { after, test } from "node:test";
import { mbReaderBinary } from "../src/read/mb-reader.ts";
import { MANUAL, Store } from "../src/store/store.ts";
import { claudeProject } from "./usage-counter-reference.ts";

const binary = mbReaderBinary();
const skip = binary === null ? "the MoonBit program (stillfail-reader) is not built here" : process.platform === "win32" ? "the launcher's descriptors are Unix's" : false;

const dirs: string[] = [];
const fresh = (what: string) => {
  const dir = mkdtempSync(join(process.platform === "darwin" ? "/tmp" : tmpdir(), `mb-reclaim-${what}-`));
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

function git(cwd: string, args: string[]): string {
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
    },
  }).trim();
}

function initRepo(dir: string, withBareRemote?: string, remoteUrl?: string): string {
  mkdirSync(dir, { recursive: true });
  git(dir, ["init", "-b", "main"]);
  writeFileSync(join(dir, "README.md"), "hello\n");
  git(dir, ["add", "README.md"]);
  git(dir, ["commit", "-m", "init"]);
  if (withBareRemote !== undefined) {
    mkdirSync(withBareRemote, { recursive: true });
    git(withBareRemote, ["init", "--bare"]);
    git(dir, ["remote", "add", "origin", withBareRemote]);
    git(dir, ["push", "-u", "origin", "main"]);
    if (remoteUrl !== undefined) git(dir, ["remote", "set-url", "origin", remoteUrl]);
  }
  return dir;
}

function setRepoMtime(repo: string, ms: number): void {
  const sec = ms / 1000;
  for (const rel of [".git/HEAD", ".git/FETCH_HEAD", ".git/index", ".git/logs/HEAD"]) {
    const p = join(repo, rel);
    if (existsSync(p)) utimesSync(p, sec, sec);
  }
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
    env: { ...process.env, STILLFAIL_PARTS_DOOR: "1", STILLFAIL_LOCAL_ADMIN: "1" },
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

test("MoonBit station reclaims worktrees, exclusive transcripts, and eligible clones while preserving all counterexamples", { skip }, async () => {
  const data = fresh("data");
  const app = fresh("app");
  const customAgentHome = fresh("agent-home");
  const remotes = fresh("remotes");
  const externalRoot = fresh("external");
  const userHome = fresh("user-home");

  mkdirSync(join(data, "repos"), { recursive: true });
  mkdirSync(join(data, "sessions", "cl"), { recursive: true });
  mkdirSync(join(data, "homes", "cc"), { recursive: true });
  mkdirSync(join(data, "mesh"), { recursive: true });
  writeFileSync(join(data, "mesh", "cloud.json"), JSON.stringify({
    origin: "http://127.0.0.1:1",
    workspace: "ws-1",
    station: "st-1",
    name: "mb-reclaim",
    memberships: [{ workspace: "ws-1", home: true }],
  }));
  writeFileSync(join(data, "config.json"), JSON.stringify({
    agentHome: customAgentHome,
    profiles: [
      { id: "cc", name: "CC", runtime: "claude", runtimes: ["claude"], home: join(data, "homes", "cc") },
      { id: "user-cc", name: "User CC", runtime: "claude", runtimes: ["claude"], home: userHome },
    ],
    connects: [{ id: "cl", kind: "slack", mode: "multi-session", bind: { runtime: "claude", profile: "cc" } }],
  }));

  const now = 1_800_000_000_000;
  const oldMs = now - 20 * 24 * 3_600_000;

  // ── Setup for Item 2 (Upkeep pruneRepoWorktrees) ──
  const wtRepo = initRepo(join(data, "repos", "wt-repo"), join(remotes, "wt-repo.git"), "https://github.com/example/wt-repo.git");
  const staleSessWt = join(data, "sessions", "cl", "gone", "workspace", "wt-stale");
  mkdirSync(dirname(staleSessWt), { recursive: true });
  git(wtRepo, ["worktree", "add", "-b", "b-stale", staleSessWt]);
  rmSync(staleSessWt, { recursive: true, force: true });

  const lockedSessWt = join(data, "sessions", "cl", "locked", "workspace", "wt-locked");
  mkdirSync(dirname(lockedSessWt), { recursive: true });
  git(wtRepo, ["worktree", "add", "-b", "b-locked", lockedSessWt]);
  rmSync(lockedSessWt, { recursive: true, force: true });
  writeFileSync(join(wtRepo, ".git", "worktrees", "wt-locked", "locked"), "archived\n");

  const extWt = join(externalRoot, "user-wt");
  git(wtRepo, ["worktree", "add", "-b", "b-ext", extWt]);
  rmSync(extWt, { recursive: true, force: true });

  // ── Setup for Item 4 (relieve_repos) ──
  const eligible = initRepo(join(data, "repos", "eligible"), join(remotes, "eligible.git"), "https://github.com/example/eligible.git");
  setRepoMtime(eligible, oldMs);

  const unpushed = initRepo(join(data, "repos", "unpushed"), join(remotes, "unpushed.git"), "https://github.com/example/unpushed.git");
  writeFileSync(join(unpushed, "a.txt"), "local\n");
  git(unpushed, ["add", "a.txt"]);
  git(unpushed, ["commit", "-m", "local"]);
  setRepoMtime(unpushed, oldMs);

  const detached = initRepo(join(data, "repos", "detached"), join(remotes, "detached.git"), "https://github.com/example/detached.git");
  git(detached, ["checkout", "--detach", "HEAD"]);
  writeFileSync(join(detached, "d.txt"), "detached\n");
  git(detached, ["add", "d.txt"]);
  git(detached, ["commit", "-m", "detached"]);
  setRepoMtime(detached, oldMs);

  const untracked = initRepo(join(data, "repos", "untracked"), join(remotes, "untracked.git"), "https://github.com/example/untracked.git");
  git(untracked, ["config", "status.showUntrackedFiles", "no"]);
  writeFileSync(join(untracked, "u.txt"), "untracked\n");
  setRepoMtime(untracked, oldMs);

  const localRemote = initRepo(join(data, "repos", "local-remote"), join(remotes, "local.git"));
  setRepoMtime(localRemote, oldMs);

  const presetRepo = initRepo(join(data, "repos", "preset-repo"), join(remotes, "preset.git"), "https://github.com/example/preset.git");
  setRepoMtime(presetRepo, oldMs);
  writeFileSync(join(customAgentHome, "presets.json"), JSON.stringify({
    presets: [{ id: "p1", name: "P1", dirs: [{ path: presetRepo, repo: null }], instructions: "" }],
    gone: [],
  }));

  const presetCopyRepo = initRepo(join(data, "repos", "preset-copy-repo"), join(remotes, "pcopy.git"), "https://github.com/example/pcopy.git");
  setRepoMtime(presetCopyRepo, oldMs);

  // ── Setup for Items 1, 3, 5 (delete_session, transcripts.exclusive, fs.rmRoom) ──
  const store = Store.open(join(data, "stillfail.db"));
  const recentAt = Date.now();
  const wsEx = join(data, "sessions", "cl", "s-ex", "workspace");
  mkdirSync(wsEx, { recursive: true });
  git(wtRepo, ["worktree", "add", "-b", "b-ex", join(wsEx, "ex-wt")]);
  store.insertSession({
    key: "s-ex", connect: "cl", runtime: "claude", profile: "cc",
    workspace: wsEx, runtimeSessionId: "ex-id", token: "tok-ex", createdAt: recentAt, lastActiveAt: recentAt,
  });
  store.ranIn("s-ex", "ex-id", "cc");
  const exProj = join(data, "transcripts", "claude", claudeProject(wsEx));
  mkdirSync(join(exProj, "ex-id", "tool-results"), { recursive: true });
  const exMain = join(exProj, "ex-id.jsonl");
  const exTool = join(exProj, "ex-id", "tool-results", "x.txt");
  writeFileSync(exMain, '{"type":"user","message":{"content":"hi"}}\n');
  writeFileSync(exTool, "tool output\n");

  // Shared transcript with another ARCHIVED session
  const wsShA = join(data, "sessions", "cl", "s-sha", "workspace");
  const wsShB = join(data, "sessions", "cl", "s-shb", "workspace");
  mkdirSync(wsShA, { recursive: true });
  mkdirSync(wsShB, { recursive: true });
  store.insertSession({
    key: "s-sha", connect: "cl", runtime: "claude", profile: "cc",
    workspace: wsShA, runtimeSessionId: "sh-id", token: "tok-sha", createdAt: recentAt, lastActiveAt: recentAt,
  });
  store.ranIn("s-sha", "sh-id", "cc");
  store.insertSession({
    key: "s-shb", connect: "cl", runtime: "claude", profile: "cc",
    workspace: wsShB, runtimeSessionId: "sh-id", token: "tok-shb", createdAt: recentAt, lastActiveAt: recentAt,
  });
  store.ranIn("s-shb", "sh-id", "cc");
  store.setArchived("s-shb", true, MANUAL);
  const shProj = join(data, "transcripts", "claude", claudeProject(wsShA));
  mkdirSync(shProj, { recursive: true });
  const shMain = join(shProj, "sh-id.jsonl");
  writeFileSync(shMain, '{"type":"user","message":{"content":"shared"}}\n');

  // External workspace + external user profile home transcript
  const extUserDir = join(externalRoot, "user-project");
  mkdirSync(extUserDir, { recursive: true });
  const extUserFile = join(extUserDir, "keep.txt");
  writeFileSync(extUserFile, "keep\n");
  store.insertSession({
    key: "s-ext", connect: "cl", runtime: "claude", profile: "user-cc",
    workspace: extUserDir, runtimeSessionId: "user-id", token: "tok-ext", createdAt: recentAt, lastActiveAt: recentAt,
  });
  store.ranIn("s-ext", "user-id", "user-cc");
  const userTranscript = join(userHome, "projects", claudeProject(extUserDir), "user-id.jsonl");
  mkdirSync(dirname(userTranscript), { recursive: true });
  writeFileSync(userTranscript, '{"type":"user","message":{"content":"mine"}}\n');

  // Unarchived session with .stillfail-preset.json referencing presetCopyRepo
  const wsPCopy = join(data, "sessions", "cl", "s-pcopy", "workspace");
  mkdirSync(wsPCopy, { recursive: true });
  writeFileSync(join(wsPCopy, ".stillfail-preset.json"), JSON.stringify({
    id: "gone-p", name: "Gone Preset", dirs: [{ path: presetCopyRepo, repo: null }], instructions: "",
  }));
  store.insertSession({
    key: "s-pcopy", connect: "cl", runtime: "claude", profile: "cc",
    workspace: wsPCopy, cwd: null, runtimeSessionId: null, token: "tok-pcopy", createdAt: recentAt, lastActiveAt: recentAt,
  });
  store.close();

  const launched = await launch(data, app);
  try {
    const served = await launched.next("mcp serving", (m) => m.serving === "mcp");
    const port = served.port as number;

    // 1. Upkeep prunes stale unlocked <data>/repos worktree, preserves locked and external
    const up = await httpJson(port, "POST", "/parts/ask/upkeep");
    assert.equal(up.status, 200, JSON.stringify(up));
    assert.ok(!existsSync(join(wtRepo, ".git", "worktrees", "wt-stale")), "MoonBit upkeep removed stale unlocked registration");
    assert.ok(existsSync(join(wtRepo, ".git", "worktrees", "wt-locked")), "MoonBit upkeep preserved locked registration");
    assert.ok(existsSync(join(wtRepo, ".git", "worktrees", "user-wt")), "MoonBit upkeep preserved external worktree registration");

    // 2. Corrupted presets.json aborts relieve_repos completely
    writeFileSync(join(customAgentHome, "presets.json"), "{broken");
    const relCorrupt = await httpJson(port, "POST", "/parts/ask/upkeep.relieveRepos", [now, 1e18]);
    assert.equal(relCorrupt.status, 200, JSON.stringify(relCorrupt));
    assert.deepEqual(relCorrupt.body, []);
    assert.ok(existsSync(eligible), "corrupted presets.json prevented deleting eligible clone");

    // Restore valid presets.json and run relieve_repos
    writeFileSync(join(customAgentHome, "presets.json"), JSON.stringify({
      presets: [{ id: "p1", name: "P1", dirs: [{ path: presetRepo, repo: null }], instructions: "" }],
      gone: [],
    }));
    const rel = await httpJson(port, "POST", "/parts/ask/upkeep.relieveRepos", [now, 1e18]);
    assert.equal(rel.status, 200, JSON.stringify(rel));
    assert.deepEqual(rel.body, ["eligible"]);
    assert.ok(!existsSync(eligible), "MoonBit relieve_repos deleted eligible clone");
    for (const kept of [wtRepo, unpushed, detached, untracked, localRemote, presetRepo, presetCopyRepo]) {
      assert.ok(existsSync(kept), `MoonBit relieve_repos MUST NOT delete: ${kept}`);
    }

    // 3. delete_session on exclusive session removes room, worktree registration, main transcript, and tool-results dir
    const delEx = await httpJson(port, "DELETE", "/admin-api/sessions/s-ex");
    assert.equal(delEx.status, 200, JSON.stringify(delEx));
    assert.ok(!existsSync(dirname(wsEx)), "MoonBit delete_session removed session room");
    assert.ok(!existsSync(join(wtRepo, ".git", "worktrees", "ex-wt")), "MoonBit delete_session removed session worktree registration");
    assert.ok(!existsSync(exMain), "MoonBit delete_session removed exclusive transcript");
    assert.ok(!existsSync(exTool), "MoonBit delete_session removed Claude tool-results file");
    assert.ok(!existsSync(join(exProj, "ex-id")), "MoonBit delete_session removed Claude session dir");

    // 4. delete_session on shared session preserves transcript referenced by archived session
    const delSh = await httpJson(port, "DELETE", "/admin-api/sessions/s-sha");
    assert.equal(delSh.status, 200, JSON.stringify(delSh));
    assert.ok(existsSync(shMain), "MoonBit delete_session preserved transcript referenced by archived session");

    // 5. delete_session on external workspace preserves directory outside <data>/sessions and external profile transcript
    const delExt = await httpJson(port, "DELETE", "/admin-api/sessions/s-ext");
    assert.equal(delExt.status, 200, JSON.stringify(delExt));
    assert.ok(existsSync(extUserFile), "MoonBit delete_session preserved workspace outside <data>/sessions");
    assert.ok(existsSync(userTranscript), "MoonBit delete_session preserved external user profile transcript");
  } finally {
    launched.tell({ type: "stop" });
    await Promise.race([launched.ended, new Promise((r) => setTimeout(r, 3_000).unref())]);
  }
});
