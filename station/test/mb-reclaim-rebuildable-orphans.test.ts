// End-to-end tests for MoonBit station PR A reclamation (`stillfail-reader run`):
// Hub::pack_unfinished_archived (with cross-round cursor), Hub::clean_idle_rebuildable &
// Hub::relieve_idle_rebuildable (capped by measured count & memoized by last_active_at),
// and P53Upkeep::prune_orphan_rooms.
import assert from "node:assert/strict";
import { type ChildProcess, execFileSync, spawn } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, rmSync, utimesSync, writeFileSync } from "node:fs";
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
  const dir = mkdtempSync(join(process.platform === "darwin" ? "/tmp" : tmpdir(), `mb-reclaim-a-${what}-`));
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

function setMtime(path: string, ms: number): void {
  const sec = ms / 1000;
  utimesSync(path, sec, sec);
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
    // Never the host station's front (an agent's environment once carried it): this test station binds a key of its own.
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

test("MoonBit station backfills unfinished archives, cleans idle unarchived rebuildables (with memo), and prunes orphan rooms", { skip }, async () => {
  const data = fresh("data");
  const app = fresh("app");
  mkdirSync(join(data, "repos"), { recursive: true });
  mkdirSync(join(data, "sessions", "cl"), { recursive: true });
  mkdirSync(join(data, "homes", "cc"), { recursive: true });
  mkdirSync(join(data, "mesh"), { recursive: true });
  writeFileSync(join(data, "mesh", "cloud.json"), JSON.stringify({
    origin: "http://127.0.0.1:1",
    workspace: "ws-1",
    station: "st-1",
    name: "mb-reclaim-a",
    memberships: [{ workspace: "ws-1", home: true }],
  }));
  writeFileSync(join(data, "config.json"), JSON.stringify({
    autoArchiveDays: 30,
    archivedWorkspaceDays: 7,
    profiles: [
      { id: "cc", name: "CC", runtime: "claude", runtimes: ["claude"], home: join(data, "homes", "cc") },
    ],
    connects: [{ id: "cl", kind: "slack", mode: "multi-session", bind: { runtime: "claude", profile: "cc" } }],
  }));

  const now = Date.now();
  const HOUR = 3_600_000;
  const DAY = 24 * HOUR;
  const store = Store.open(join(data, "stillfail.db"));

  // ── Item 1: two unfinished archived sessions (no `cold` mark) ──
  const wsArch1 = join(data, "sessions", "cl", "s-arch1", "workspace");
  const wsArch2 = join(data, "sessions", "cl", "s-arch2", "workspace");
  mkdirSync(wsArch1, { recursive: true });
  mkdirSync(wsArch2, { recursive: true });
  writeFileSync(join(wsArch1, "a.txt"), "archive1\n");
  writeFileSync(join(wsArch2, "b.txt"), "archive2\n");
  store.insertSession({
    key: "s-arch1", connect: "cl", runtime: "claude", profile: "cc",
    workspace: wsArch1, runtimeSessionId: null, token: "tok-a1", createdAt: now - 2 * DAY, lastActiveAt: now - 2 * DAY,
  });
  store.setArchived("s-arch1", true, MANUAL);
  store.db.prepare("UPDATE sessions SET archived_at = ? WHERE key = ?").run(now - 2 * DAY, "s-arch1");
  store.insertSession({
    key: "s-arch2", connect: "cl", runtime: "claude", profile: "cc",
    workspace: wsArch2, runtimeSessionId: null, token: "tok-a2", createdAt: now - DAY, lastActiveAt: now - DAY,
  });
  store.setArchived("s-arch2", true, MANUAL);
  store.db.prepare("UPDATE sessions SET archived_at = ? WHERE key = ?").run(now - DAY, "s-arch2");

  // ── Item 2: idle unarchived sessions (25h, 23h, 2h, 30m) ──
  const makeIdle = (key: string, idleHours: number) => {
    const ws = join(data, "sessions", "cl", key, "workspace");
    mkdirSync(join(ws, "node_modules", "dep"), { recursive: true });
    writeFileSync(join(ws, "node_modules", "dep", "index.js"), "x\n".repeat(100));
    writeFileSync(join(ws, "src.ts"), "keep\n");
    const at = now - idleHours * HOUR;
    store.insertSession({
      key, connect: "cl", runtime: "claude", profile: "cc",
      workspace: ws, runtimeSessionId: null, token: `tok-${key}`, createdAt: at, lastActiveAt: at,
    });
    return ws;
  };
  const ws25h = makeIdle("s-25h", 25);
  const ws23h = makeIdle("s-23h", 23);
  const ws2h = makeIdle("s-2h", 2);
  const ws30m = makeIdle("s-30m", 0.5);

  // ── Item 3: orphan rooms (25h old with worktree, 23h fresh) ──
  const repo = join(data, "repos", "demo");
  mkdirSync(repo, { recursive: true });
  git(repo, ["init", "-b", "main"]);
  writeFileSync(join(repo, "README.md"), "hi\n");
  git(repo, ["add", "README.md"]);
  git(repo, ["commit", "-m", "init"]);

  const oldOrphanRoom = join(data, "sessions", "cl", "orphan-old");
  const oldOrphanWs = join(oldOrphanRoom, "workspace");
  mkdirSync(oldOrphanWs, { recursive: true });
  git(repo, ["worktree", "add", "-b", "b-mb-orphan", join(oldOrphanWs, "wt-mb-orphan")]);
  setMtime(oldOrphanWs, now - 25 * HOUR);
  setMtime(oldOrphanRoom, now - 25 * HOUR);

  const freshOrphanRoom = join(data, "sessions", "cl", "orphan-fresh");
  mkdirSync(join(freshOrphanRoom, "workspace"), { recursive: true });
  setMtime(join(freshOrphanRoom, "workspace"), now - 23 * HOUR);
  setMtime(freshOrphanRoom, now - 23 * HOUR);

  // ── Item 4: tightened low-disk orphan UUID transcripts (7d threshold, memory/ & non-UUID preserved) ──
  const uArch = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
  const uOld = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
  const uNew = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";
  const uStandaloneOld = "dddddddd-dddd-4ddd-8ddd-dddddddddddd";
  const uStandaloneFresh = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
  const uCodexOld = "ffffffff-ffff-4fff-8fff-ffffffffffff";

  store.ranIn("s-arch1", uArch, "cc");
  const proj = claudeProject(wsArch1);
  const txDir = join(data, "transcripts", "claude", proj);
  mkdirSync(txDir, { recursive: true });

  const memDir = join(txDir, "memory");
  mkdirSync(memDir, { recursive: true });
  const memFile = join(memDir, "MEMORY.md");
  writeFileSync(memFile, "# memory\n");
  setMtime(memFile, now - 8 * DAY);
  setMtime(memDir, now - 8 * DAY);

  const nonUuidFile = join(txDir, "agent-1234.jsonl");
  writeFileSync(nonUuidFile, "{}\n");
  setMtime(nonUuidFile, now - 8 * DAY);

  const archTx = join(txDir, `${uArch}.jsonl`);
  writeFileSync(archTx, "{}\n");
  setMtime(archTx, now - 8 * DAY);

  const oldTx = join(txDir, `${uOld}.jsonl`);
  const oldTxDir = join(txDir, uOld);
  mkdirSync(join(oldTxDir, "tool-results"), { recursive: true });
  writeFileSync(oldTx, "{}\n");
  writeFileSync(join(oldTxDir, "tool-results", "x.txt"), "res\n");
  setMtime(oldTx, now - 8 * DAY);
  setMtime(join(oldTxDir, "tool-results", "x.txt"), now - 8 * DAY);
  setMtime(join(oldTxDir, "tool-results"), now - 8 * DAY);
  setMtime(oldTxDir, now - 8 * DAY);

  const newTx = join(txDir, `${uNew}.jsonl`);
  writeFileSync(newTx, "{}\n");
  setMtime(newTx, now - 6 * DAY);

  const standaloneOldDir = join(txDir, uStandaloneOld);
  mkdirSync(join(standaloneOldDir, "tool-results"), { recursive: true });
  writeFileSync(join(standaloneOldDir, "tool-results", "old.txt"), "old\n");
  setMtime(join(standaloneOldDir, "tool-results", "old.txt"), now - 8 * DAY);
  setMtime(join(standaloneOldDir, "tool-results"), now - 8 * DAY);
  setMtime(standaloneOldDir, now - 8 * DAY);

  const standaloneFreshDir = join(txDir, uStandaloneFresh);
  mkdirSync(join(standaloneFreshDir, "tool-results"), { recursive: true });
  const freshChild = join(standaloneFreshDir, "tool-results", "new.txt");
  writeFileSync(freshChild, "new\n");
  setMtime(freshChild, now - 1 * DAY);
  setMtime(standaloneFreshDir, now - 8 * DAY);

  const codexDir = join(data, "transcripts", "codex", "2026", "11", "10");
  mkdirSync(codexDir, { recursive: true });
  const oldCodexTx = join(codexDir, `rollout-2026-11-10T00-00-00-${uCodexOld}.jsonl`);
  writeFileSync(oldCodexTx, "{}\n");
  setMtime(oldCodexTx, now - 8 * DAY);

  store.close();

  const launched = await launch(data, app);
  try {
    const served = await launched.next("mcp serving", (m) => m.serving === "mcp");
    const port = served.port as number;

    // 1. Backfill unfinished archives with limit = 1 -> round 1 packs s-arch1, round 2 advances cursor & packs s-arch2
    const p1 = await httpJson(port, "POST", "/parts/ask/hub.packUnfinishedArchived", [now, 1]);
    assert.equal(p1.status, 200, JSON.stringify(p1));
    assert.equal(p1.body, 1);
    assert.ok(existsSync(join(dirname(wsArch1), "cold")), "round 1 packed s-arch1");
    assert.ok(!existsSync(join(dirname(wsArch2), "cold")), "limit=1 deferred s-arch2");

    const p2 = await httpJson(port, "POST", "/parts/ask/hub.packUnfinishedArchived", [now, 1]);
    assert.equal(p2.status, 200, JSON.stringify(p2));
    assert.equal(p2.body, 1);
    assert.ok(existsSync(join(dirname(wsArch2), "cold")), "round 2 packed s-arch2");

    // 2. Idle unarchived rebuildable cleanup (24h threshold): measures & cleans s-25h once, memo skips on 2nd round
    const c1 = await httpJson(port, "POST", "/parts/ask/hub.cleanIdleRebuildable", [now]);
    assert.equal(c1.status, 200, JSON.stringify(c1));
    assert.equal(c1.body, 1);
    assert.ok(!existsSync(join(ws25h, "node_modules")), "25h idle node_modules removed");
    assert.ok(existsSync(join(ws25h, "src.ts")), "source preserved");
    assert.ok(!existsSync(join(dirname(ws25h), "cold")), "no cold mark written");
    assert.ok(existsSync(join(ws23h, "node_modules")), "23h idle preserved");
    assert.ok(existsSync(join(ws2h, "node_modules")), "2h idle preserved");

    const c2 = await httpJson(port, "POST", "/parts/ask/hub.cleanIdleRebuildable", [now]);
    assert.equal(c2.status, 200, JSON.stringify(c2));
    assert.equal(c2.body, 0, "memoized s-25h is not measured a second time");

    // Low-disk idle rebuildable cleanup (1h threshold): skips memoized s-25h, cleans s-23h and s-2h, keeps s-30m
    const r1 = await httpJson(port, "POST", "/parts/ask/hub.relieveIdleRebuildable", [now, 1e18]);
    assert.equal(r1.status, 200, JSON.stringify(r1));
    assert.equal(r1.body, 2);
    assert.ok(!existsSync(join(ws23h, "node_modules")), "23h idle cleaned on low disk");
    assert.ok(!existsSync(join(ws2h, "node_modules")), "2h idle cleaned on low disk");
    assert.ok(existsSync(join(ws30m, "node_modules")), "30m idle preserved on low disk");

    // 3. Orphan rooms pruning
    const or1 = await httpJson(port, "POST", "/parts/ask/upkeep.pruneOrphanRooms", [now]);
    assert.equal(or1.status, 200, JSON.stringify(or1));
    assert.deepEqual(or1.body, ["cl/orphan-old"]);
    assert.ok(!existsSync(oldOrphanRoom), "25h orphan room removed");
    assert.ok(!existsSync(join(repo, ".git", "worktrees", "wt-mb-orphan")), "orphan room worktree registration removed");
    assert.ok(existsSync(freshOrphanRoom), "23h orphan room preserved");
    assert.ok(existsSync(dirname(ws25h)), "session-backed room preserved");

    // 4. Low-disk orphan UUID transcripts: untouched when not below low, cleaned when low (full=true)
    const otSkip = await httpJson(port, "POST", "/parts/ask/upkeep.relieveOrphanTranscripts", [now, 1, false]);
    assert.equal(otSkip.status, 200, JSON.stringify(otSkip));
    assert.deepEqual(otSkip.body, [], "above low mark does not delete orphan transcripts");
    assert.ok(existsSync(oldTx));

    const otFull = await httpJson(port, "POST", "/parts/ask/upkeep.relieveOrphanTranscripts", [now, 1e18, true]);
    assert.equal(otFull.status, 200, JSON.stringify(otFull));
    assert.ok(!existsSync(oldTx), "8d orphan UUID .jsonl deleted");
    assert.ok(!existsSync(oldTxDir), "8d orphan companion <uuid>/ deleted");
    assert.ok(!existsSync(standaloneOldDir), "8d standalone <uuid>/ deleted");
    assert.ok(!existsSync(oldCodexTx), "8d orphan Codex rollout deleted");
    assert.ok(existsSync(memFile), "projects/<proj>/memory/ preserved");
    assert.ok(existsSync(nonUuidFile), "non-UUID agent-1234.jsonl preserved");
    assert.ok(existsSync(archTx) || existsSync(`${archTx}.zst`), "archived-session-referenced UUID preserved (plain or compressed by pack)");
    assert.ok(!(otFull.body as string[]).some((p) => p.includes(uArch)), "archived-session-referenced UUID not reclaimed");
    assert.ok(existsSync(newTx), "6d orphan UUID preserved");
    assert.ok(existsSync(freshChild), "standalone <uuid>/ with 1d child preserved");

    // 5. Archive upkeep cadence (10m): skips at startup, runs once across 3x1s triggers at +10m, runs again at +20m
    const MIN = 60_000;
    const base = Date.now();
    const u0 = await httpJson(port, "POST", "/parts/ask/hub.runArchiveUpkeepIfDue", [base]);
    assert.equal(u0.status, 200, JSON.stringify(u0));
    assert.equal(u0.body, false, "archive upkeep skipped immediately after startup");

    const u1 = await httpJson(port, "POST", "/parts/ask/hub.runArchiveUpkeepIfDue", [base + 10 * MIN]);
    assert.equal(u1.status, 200, JSON.stringify(u1));
    assert.equal(u1.body, true, "archive upkeep runs at +10m");

    const u2 = await httpJson(port, "POST", "/parts/ask/hub.runArchiveUpkeepIfDue", [base + 10 * MIN + 1_000]);
    assert.equal(u2.status, 200, JSON.stringify(u2));
    assert.equal(u2.body, false, "archive upkeep skipped 1s later");

    const u3 = await httpJson(port, "POST", "/parts/ask/hub.runArchiveUpkeepIfDue", [base + 10 * MIN + 2_000]);
    assert.equal(u3.status, 200, JSON.stringify(u3));
    assert.equal(u3.body, false, "archive upkeep skipped 2s later");

    const u4 = await httpJson(port, "POST", "/parts/ask/hub.runArchiveUpkeepIfDue", [base + 20 * MIN]);
    assert.equal(u4.status, 200, JSON.stringify(u4));
    assert.equal(u4.body, true, "archive upkeep runs a 2nd time at +20m");

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
