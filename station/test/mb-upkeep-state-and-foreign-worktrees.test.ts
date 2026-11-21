// End-to-end tests for MoonBit station (`stillfail-reader run`):
// (1) persistent idle_measured & last_archive_upkeep_at across real process restart + corrupted state file recovery,
// (2) persistent last_repo_branches_at across real process restart (skip within 24h, run after 24h),
// (3) foreign archived-workspace locked worktree cleanup + counterexamples.
import assert from "node:assert/strict";
import { type ChildProcess, execFileSync, spawn } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { request } from "node:http";
import { createServer, type Server } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { after, test } from "node:test";
import { mbReaderBinary } from "../src/read/mb-reader.ts";
import { ARCHIVE_WORKTREE_LOCK_PREFIX } from "../src/sessions/archive.ts";
import { UPKEEP_STATE_FILE } from "../src/ops/upkeep-state.ts";
import { Store } from "../src/store/store.ts";

const binary = mbReaderBinary();
const skip =
  binary === null
    ? "the MoonBit program (stillfail-reader) is not built here"
    : process.platform === "win32"
      ? "the launcher's descriptors are Unix's"
      : false;

const dirs: string[] = [];
const fresh = (what: string) => {
  const dir = mkdtempSync(join(process.platform === "darwin" ? "/tmp" : tmpdir(), `mb-upkeep-fix-${what}-`));
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

function git(cwd: string, args: string[], envExtra?: Record<string, string>): string {
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
      ...envExtra,
    },
  }).trim();
}

function branchExists(repo: string, name: string): boolean {
  try {
    git(repo, ["show-ref", "--verify", "--quiet", `refs/heads/${name}`]);
    return true;
  } catch {
    return false;
  }
}

function withoutFront(): NodeJS.ProcessEnv {
  const env = { ...process.env };
  delete env.STILLFAIL_MESH_FRONT;
  return env;
}

async function launch(data: string, app: string) {
  const listener = () =>
    new Promise<Server>((resolve) => {
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
  const stop = async () => {
    if (child.exitCode === null && child.signalCode === null) {
      tell({ op: "stop" });
      assert.equal(await ended, 0, err);
    }
  };
  return { child, next, tell, ended, stop, err: () => err };
}

function httpJson(port: number, method: string, path: string, body?: unknown): Promise<{ status: number; body: any }> {
  return new Promise((resolve, reject) => {
    const data = body === undefined ? null : JSON.stringify(body);
    const req = request(
      {
        host: "127.0.0.1",
        port,
        method,
        path,
        headers: data === null ? {} : { "content-type": "application/json", "content-length": Buffer.byteLength(data) },
      },
      (res) => {
        let text = "";
        res.setEncoding("utf8");
        res.on("data", (d) => (text += d));
        res.on("end", () => {
          let parsed: any = text;
          try {
            parsed = JSON.parse(text);
          } catch {}
          resolve({ status: res.statusCode ?? 0, body: parsed });
        });
      },
    );
    req.on("error", reject);
    if (data !== null) req.write(data);
    req.end();
  });
}

test("MoonBit station persists idle_measured & daily branch cleanup timestamps across restarts and prunes foreign locked worktrees", { skip }, async () => {
  const data = fresh("data");
  const app = fresh("app");
  const external = fresh("ext");
  mkdirSync(join(data, "repos"), { recursive: true });
  mkdirSync(join(data, "sessions", "cl"), { recursive: true });
  mkdirSync(join(data, "homes", "cc"), { recursive: true });
  mkdirSync(join(data, "mesh"), { recursive: true });
  writeFileSync(
    join(data, "mesh", "cloud.json"),
    JSON.stringify({
      origin: "http://127.0.0.1:1",
      workspace: "ws-1",
      station: "st-1",
      name: "mb-upkeep-fix",
      memberships: [{ workspace: "ws-1", home: true }],
    }),
  );
  writeFileSync(
    join(data, "config.json"),
    JSON.stringify({
      autoArchiveDays: 30,
      archivedWorkspaceDays: 7,
      profiles: [{ id: "cc", name: "CC", runtime: "claude", runtimes: ["claude"], home: join(data, "homes", "cc") }],
      connects: [{ id: "cl", kind: "slack", mode: "multi-session", bind: { runtime: "claude", profile: "cc" } }],
    }),
  );

  const HOUR = 3_600_000;
  const DAY = 24 * HOUR;
  const t0 = Date.now();

  // ── Seed 40 idle unarchived sessions (>24h idle) ──
  const store = Store.open(join(data, "stillfail.db"));
  const workspaces: string[] = [];
  for (let i = 0; i < 40; i++) {
    const key = `s-${String(i).padStart(2, "0")}`;
    const ws = join(data, "sessions", "cl", key, "workspace");
    mkdirSync(join(ws, "node_modules", "dep"), { recursive: true });
    writeFileSync(join(ws, "node_modules", "dep", "index.js"), "x\n");
    writeFileSync(join(ws, "src.ts"), `export const i = ${i};\n`);
    const activeAt = t0 - 48 * HOUR + i * 1_000;
    store.insertSession({
      key,
      connect: "cl",
      runtime: "claude",
      profile: "cc",
      workspace: ws,
      runtimeSessionId: null,
      token: `tok-${key}`,
      createdAt: activeAt,
      lastActiveAt: activeAt,
    });
    workspaces.push(ws);
  }
  store.close();

  // ── Seed shared repo for daily branch cleanup & foreign locked worktrees ──
  const remote = join(fresh("remote"), "origin.git");
  mkdirSync(remote, { recursive: true });
  git(remote, ["init", "--bare", "-b", "main"]);
  const repo = join(data, "repos", "demo");
  mkdirSync(repo, { recursive: true });
  const oldSec = Math.floor((t0 - 5 * DAY) / 1000);
  const oldEnv = { GIT_AUTHOR_DATE: `${oldSec} +0000`, GIT_COMMITTER_DATE: `${oldSec} +0000` };
  git(repo, ["init", "-b", "main"]);
  git(repo, ["remote", "add", "origin", remote]);
  writeFileSync(join(repo, "README.md"), "hi\n");
  git(repo, ["add", "README.md"]);
  git(repo, ["commit", "-m", "init"], oldEnv);
  git(repo, ["push", "-u", "origin", "main"]);

  git(repo, ["branch", "b1", "main"]);
  rmSync(join(repo, ".git", "logs", "refs", "heads", "b1"), { force: true });
  execFileSync("touch", ["-t", "202001010000", join(repo, ".git", "refs", "heads", "b1")]);

  // Worktree registrations (Item 3)
  const addWt = (name: string, gitdir: string, locked?: string) => {
    const dir = join(repo, ".git", "worktrees", name);
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "gitdir"), `${gitdir}\n`);
    if (locked !== undefined) writeFileSync(join(dir, "locked"), locked);
    return dir;
  };
  const foreignGone = addWt(
    "wt-foreign-gone",
    "/Users/other-machine/.stillfail/sessions/chat/c-111/workspace/repo/.git",
    `${ARCHIVE_WORKTREE_LOCK_PREFIX}/Users/other-machine/.stillfail/sessions/chat/c-111\n`,
  );
  const localRoom = join(data, "sessions", "chat", "c-local");
  const localLocked = addWt(
    "wt-local-locked",
    join(localRoom, "workspace", "repo", ".git"),
    `${ARCHIVE_WORKTREE_LOCK_PREFIX}${localRoom}\n`,
  );
  const userLocked = addWt("wt-user-locked", "/Users/other-machine/dev/wt/.git", "manual lock\n");
  const existingTargetDir = join(external, "still-here", "workspace", "repo");
  mkdirSync(existingTargetDir, { recursive: true });
  const existingTargetGit = join(existingTargetDir, ".git");
  writeFileSync(existingTargetGit, "gitdir: /dummy\n");
  const foreignExists = addWt(
    "wt-foreign-exists",
    existingTargetGit,
    `${ARCHIVE_WORKTREE_LOCK_PREFIX}${join(external, "still-here")}\n`,
  );
  const extRepo = join(external, "ext-repo");
  const extWt = join(extRepo, ".git", "worktrees", "wt-ext-foreign");
  mkdirSync(extWt, { recursive: true });
  writeFileSync(join(extWt, "gitdir"), "/Users/other-machine/.stillfail/sessions/chat/c-222/workspace/r/.git\n");
  writeFileSync(join(extWt, "locked"), `${ARCHIVE_WORKTREE_LOCK_PREFIX}/Users/other-machine/.stillfail/sessions/chat/c-222\n`);
  symlinkSync(extRepo, join(data, "repos", "linked-repo"));

  // ── Launch #1 ──
  const l1 = await launch(data, app);
  try {
    const port1 = (await l1.next("mcp serving", (m) => m.serving === "mcp")).port as number;

    // Item 3: pruneRepoWorktrees
    const wtRes = await httpJson(port1, "POST", "/parts/ask/upkeep.pruneRepoWorktrees", []);
    assert.equal(wtRes.status, 200, JSON.stringify(wtRes));
    assert.deepEqual(wtRes.body, ["demo/wt-foreign-gone"]);
    assert.ok(!existsSync(foreignGone), "foreign locked missing registration pruned");
    assert.ok(existsSync(localLocked), "local locked registration preserved");
    assert.ok(existsSync(userLocked), "non-station-prefix locked registration preserved");
    assert.ok(existsSync(foreignExists), "foreign locked registration with existing target preserved");
    assert.ok(existsSync(extWt), "symlinked external repo worktree preserved");

    // Item 1: round 1 measures first 16 idle sessions (s-00..s-15)
    const c1 = await httpJson(port1, "POST", "/parts/ask/hub.cleanIdleRebuildable", [t0]);
    assert.equal(c1.status, 200, JSON.stringify(c1));
    assert.equal(c1.body, 16);
    for (let i = 0; i < 16; i++) assert.ok(!existsSync(join(workspaces[i]!, "node_modules")), `round 1 cleaned s-${i}`);
    for (let i = 16; i < 40; i++) assert.ok(existsSync(join(workspaces[i]!, "node_modules")), `round 1 deferred s-${i}`);

    // Item 2: upkeep pass runs branch cleanup at t0 and persists lastRepoBranchesAt
    const u1 = await httpJson(port1, "POST", "/parts/ask/upkeep", [t0]);
    assert.equal(u1.status, 200, JSON.stringify(u1));
    assert.ok(!branchExists(repo, "b1"), "upkeep round 1 pruned b1");

    const stateFile = join(data, UPKEEP_STATE_FILE);
    assert.ok(existsSync(stateFile), "upkeep-state.json persisted");
    const saved = JSON.parse(readFileSync(stateFile, "utf8"));
    assert.equal(Object.keys(saved.idleMeasured).length, 16);
    assert.equal(saved.lastRepoBranchesAt, t0);

    await l1.stop();
  } finally {
    await l1.stop();
  }

  // Add second merged branch b2 while stopped
  git(repo, ["branch", "b2", "main"]);
  rmSync(join(repo, ".git", "logs", "refs", "heads", "b2"), { force: true });
  execFileSync("touch", ["-t", "202001010000", join(repo, ".git", "refs", "heads", "b2")]);

  // ── Launch #2 (real process restart on same <data>) ──
  const l2 = await launch(data, app);
  try {
    const port2 = (await l2.next("mcp serving", (m) => m.serving === "mcp")).port as number;

    // Item 1: round 2 after restart measures the NEXT 16 sessions (s-16..s-31), NOT s-00..s-15
    const c2 = await httpJson(port2, "POST", "/parts/ask/hub.cleanIdleRebuildable", [t0]);
    assert.equal(c2.status, 200, JSON.stringify(c2));
    assert.equal(c2.body, 16);
    for (let i = 0; i < 32; i++) assert.ok(!existsSync(join(workspaces[i]!, "node_modules")), `round 2 cleaned s-${i}`);
    for (let i = 32; i < 40; i++) assert.ok(existsSync(join(workspaces[i]!, "node_modules")), `round 2 deferred s-${i}`);

    // Item 2: upkeep pass at t0 + 1h skips branch cleanup across restart; at t0 + 24h runs it
    const u2a = await httpJson(port2, "POST", "/parts/ask/upkeep", [t0 + HOUR]);
    assert.equal(u2a.status, 200, JSON.stringify(u2a));
    assert.ok(branchExists(repo, "b2"), "restarted MoonBit station skipped branch cleanup within 24h");

    const u2b = await httpJson(port2, "POST", "/parts/ask/upkeep", [t0 + DAY]);
    assert.equal(u2b.status, 200, JSON.stringify(u2b));
    assert.ok(!branchExists(repo, "b2"), "MoonBit station ran branch cleanup again after 24h");

    await l2.stop();
  } finally {
    await l2.stop();
  }

  // ── Launch #3: corrupted upkeep-state.json recovers cleanly ──
  writeFileSync(join(data, UPKEEP_STATE_FILE), "{corrupt!!!");
  const l3 = await launch(data, app);
  try {
    const port3 = (await l3.next("mcp serving", (m) => m.serving === "mcp")).port as number;
    const c3 = await httpJson(port3, "POST", "/parts/ask/hub.cleanIdleRebuildable", [t0, 24 * HOUR, 16]);
    assert.equal(c3.status, 200, JSON.stringify(c3));
    assert.equal(c3.body, 16, "corrupted state file treated as empty without failing");
    const repaired = JSON.parse(readFileSync(join(data, UPKEEP_STATE_FILE), "utf8"));
    assert.equal(Object.keys(repaired.idleMeasured).length, 16);
    await l3.stop();
  } finally {
    await l3.stop();
  }
});
