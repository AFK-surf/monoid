// Dual-engine MB vs Pion `--data <dir>` parity, pool/OwnReader switching, concurrency,
// and mixed-mode LiveHub (--data=pion + --sessions=mb) verification (zero setTimeout sleeps).

import assert from "node:assert/strict";
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import {
  appendFileSync,
  cpSync,
  mkdirSync,
  mkdtempSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import test from "node:test";
import { zstdCompressSync } from "node:zlib";
import {
  MbProcess,
  mbReaderBinary,
  pionBinary,
  resetReaderSelectionStateForTest,
  resolveReaderSelectionAsync,
  setPionProbeRunnerForTest,
} from "../src/read/mb-reader.ts";
import { Readers } from "../src/read/pool.ts";
import type { ReaderSelectConfig } from "../src/read/reader-select.ts";
import { LiveHub, OwnReader } from "../src/sessions/live.ts";
import { Store } from "../src/store/store.ts";

const REQUIRE_DUAL = process.env.STILLFAIL_REQUIRE_DUAL_READER === "1";

function resolveDualBinaries(): { mb: string; pion: string } | null {
  const mb = mbReaderBinary();
  const pion = pionBinary();
  if (!mb || !pion) {
    if (REQUIRE_DUAL) {
      assert.fail(`STILLFAIL_REQUIRE_DUAL_READER=1 requires both binaries (mb=${mb}, pion=${pion})`);
    }
    return null;
  }
  const mbReal = realpathSync(mb);
  const pionReal = realpathSync(pion);
  assert.notEqual(
    mbReal,
    pionReal,
    `MB and Pion binaries must be distinct executables (both resolved to ${mbReal})`,
  );
  return { mb: mbReal, pion: pionReal };
}

/** Raw stdio framed client for direct wire-level parity (header bytes, U+2028/U+2029, lone surrogate). */
class RawDataClient {
  #proc: ChildProcessWithoutNullStreams;
  #buf: Buffer = Buffer.alloc(0);
  #waiters: Array<() => void> = [];
  #closed = false;
  #stderr = "";

  constructor(binary: string, dataDir: string) {
    this.#proc = spawn(binary, ["--data", dataDir], {
      stdio: ["pipe", "pipe", "pipe"],
    });
    this.#proc.stdout.on("data", (chunk: Buffer) => {
      this.#buf = this.#buf.length === 0 ? chunk : Buffer.concat([this.#buf, chunk]);
      this.#wake();
    });
    this.#proc.stderr.on("data", (chunk: Buffer) => {
      this.#stderr += chunk.toString("utf8");
    });
    this.#proc.on("exit", () => {
      this.#closed = true;
      this.#wake();
    });
  }

  #wake(): void {
    const ws = this.#waiters.splice(0);
    for (const w of ws) w();
  }

  async #waitData(): Promise<void> {
    if (this.#closed) {
      throw new Error(`reader exited unexpectedly (stderr=${this.#stderr})`);
    }
    await new Promise<void>((resolve) => this.#waiters.push(resolve));
  }

  async readLineRaw(): Promise<Buffer> {
    while (true) {
      const nl = this.#buf.indexOf(0x0a);
      if (nl >= 0) {
        const line = this.#buf.subarray(0, nl);
        this.#buf = this.#buf.subarray(nl + 1);
        return line;
      }
      await this.#waitData();
    }
  }

  async readExact(n: number): Promise<Buffer> {
    while (this.#buf.length < n) {
      await this.#waitData();
    }
    const out = this.#buf.subarray(0, n);
    this.#buf = this.#buf.subarray(n);
    return out;
  }

  async ready(): Promise<unknown> {
    const line = await this.readLineRaw();
    return JSON.parse(line.toString("utf8"));
  }

  async askRaw(rawLine: string): Promise<{
    headRaw: string;
    head: Record<string, unknown>;
    body: string | null;
  }> {
    this.#proc.stdin.write(rawLine + "\n");
    const headBuf = await this.readLineRaw();
    const headRaw = headBuf.toString("utf8");
    const head = JSON.parse(headRaw) as Record<string, unknown>;
    if (typeof head.bytes === "number") {
      const bodyBuf = await this.readExact(head.bytes);
      return { headRaw, head, body: bodyBuf.toString("utf8") };
    }
    return { headRaw, head, body: null };
  }

  async ask(obj: Record<string, unknown>): Promise<{
    headRaw: string;
    head: Record<string, unknown>;
    body: string | null;
  }> {
    return this.askRaw(JSON.stringify(obj));
  }

  async close(): Promise<number> {
    this.#proc.stdin.end();
    if (this.#closed) return this.#proc.exitCode ?? 0;
    return await new Promise<number>((resolve) => {
      this.#proc.once("exit", (code) => resolve(code ?? 0));
    });
  }
}

/** Build a rich deterministic station fixture exercising all 54 ops. */
function buildStationFixture(root: string): {
  dataDir: string;
  transcriptPath: string;
  threadId: number;
  sessionKey: string;
  jobId: string;
  viewer: {
    email: string;
    home: boolean;
    workspace: string | null;
    slack: string[];
    workspaces: string[];
    roles: Record<string, string>;
  };
} {
  const dataDir = join(root, "source");
  mkdirSync(join(dataDir, "archive"), { recursive: true });
  mkdirSync(join(dataDir, "memory", "skills", "custom-skill"), { recursive: true });
  mkdirSync(join(dataDir, "jobs"), { recursive: true });
  mkdirSync(join(dataDir, "transcripts"), { recursive: true });

  writeFileSync(join(dataDir, "memory", "MEMORY.md"), "- keep tests deterministic\n", "utf8");
  writeFileSync(
    join(dataDir, "memory", "skills", "custom-skill", "SKILL.md"),
    "---\nname: custom-skill\ndescription: Custom test skill\n---\n# Custom\n",
    "utf8",
  );
  writeFileSync(
    join(dataDir, "config.json"),
    JSON.stringify({
      stationName: "test-station",
      workspaces: [{ id: "ws1", name: "Workspace One" }],
      connects: [{ id: "c1", kind: "slack", team: "T1", workspace: "ws1" }],
    }),
    "utf8",
  );

  const jobId = "job-1";
  const jobLogPath = join(dataDir, "jobs", "job-1.log");
  writeFileSync(jobLogPath, "line 1\nline 2\nline 3\n", "utf8");

  const transcriptPath = join(dataDir, "transcripts", "s1.jsonl");
  const at = "2026-11-25T00:00:00.000Z";
  writeFileSync(
    transcriptPath,
    [
      JSON.stringify({ type: "user", timestamp: at, message: { role: "user", content: "hello agent" } }),
      JSON.stringify({
        type: "assistant",
        timestamp: at,
        message: {
          id: "m1",
          model: "claude-opus-4-6",
          usage: { input_tokens: 100, output_tokens: 50 },
          content: [{ type: "text", text: "hello person" }],
        },
      }),
    ].join("\n") + "\n",
    "utf8",
  );

  const store = Store.open(join(dataDir, "stillfail.db"), join(dataDir, "archive"));
  const db = store.db;
  const sessionKey = "s-alpha";
  const now = 1795580000000;

  // Thread + session + bindings + entries + turns + jobs + usage + cards + mesh
  const insThread = db.prepare(
    `INSERT INTO threads (surface, channel, thread_ts, title, created_by, created_at, home, project, project_locked, tags)
     VALUES ('chat', 'CHAT', '1795580000.000001', 'Alpha Chat', 'alice@example.com', ?, ?, 'monoid', 1, '["backend","ops"]')`,
  );
  const threadId = Number(insThread.run(now - 60000, sessionKey).lastInsertRowid);

  db.prepare(
    `INSERT INTO sessions (key, connect, scope, title, created_by, runtime, profile, model, runtime_session_id, workspace, token, running, created_at, last_active_at, cwd)
     VALUES (?, 'chat', 'ws1', 'Alpha Chat', 'alice@example.com', 'claude', 'default', 'claude-opus-4-6', 'rt-alpha', ?, 'tok-alpha', 0, ?, ?, ?)`,
  ).run(sessionKey, dataDir, now - 60000, now - 1000, dataDir);

  db.prepare(
    `INSERT INTO thread_sessions (thread, session, connect, joined_at) VALUES (?, ?, 'chat', ?)`,
  ).run(threadId, sessionKey, now - 60000);

  db.prepare(
    `INSERT INTO entries (thread, n, kind, ts, author_kind, author, text, at)
     VALUES (?, 1, 'message', '1795580001.000001', 'person', 'alice@example.com', 'hi alpha', ?)`,
  ).run(threadId, now - 50000);
  db.prepare(
    `INSERT INTO entries (thread, n, kind, ts, author_kind, author, text, at)
     VALUES (?, 2, 'message', '1795580002.000001', 'agent', ?, 'working on it', ?)`,
  ).run(threadId, sessionKey, now - 40000);

  db.prepare(
    `INSERT INTO turns (id, session_key, kind, started_at, ended_at, outcome, detail, declared)
     VALUES ('t1', ?, 'message', ?, ?, 'ok', 'finished alpha', 'all_done')`,
  ).run(sessionKey, now - 45000, now - 35000);

  db.prepare(
    `INSERT INTO jobs (id, session_key, name, command, cwd, token, state, exit_code, started_at, ended_at, log, watch)
     VALUES (?, ?, 'build', 'echo ok', ?, 'jtok-1', 'exited', 0, ?, ?, ?, 0)`,
  ).run(jobId, sessionKey, dataDir, now - 30000, now - 25000, jobLogPath);

  db.prepare(
    `INSERT INTO mesh_announcements (scope, node, revision, body, signature)
     VALUES ('ws1', 'node-a', 1, '{"a":1}', 'sig-a')`,
  ).run();

  store.close();

  return {
    dataDir,
    transcriptPath,
    threadId,
    sessionKey,
    jobId,
    viewer: {
      email: "alice@example.com",
      home: true,
      workspace: null,
      slack: [],
      workspaces: ["ws1"],
      roles: { ws1: "owner" },
    },
  };
}

test("all 54 ops + changed sublists + Refused/500 + catalog + framing parity (MB vs Pion on independent copies)", async (t) => {
  const bins = resolveDualBinaries();
  if (!bins) return;

  const root = mkdtempSync(join(tmpdir(), "w7f-54ops-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));

  const fx = buildStationFixture(root);
  const mbDir = join(root, "mb-copy");
  const pionDir = join(root, "pion-copy");
  cpSync(fx.dataDir, mbDir, { recursive: true });
  cpSync(fx.dataDir, pionDir, { recursive: true });

  const mb = new RawDataClient(bins.mb, mbDir);
  const pion = new RawDataClient(bins.pion, pionDir);
  t.after(async () => {
    await Promise.all([mb.close(), pion.close()]);
  });

  const mbReady = await mb.ready();
  const pionReady = await pion.ready();
  assert.deepEqual(pionReady, mbReady, "ready handshake mismatch");

  const now = 1795580000000;
  const baseAsk = {
    lang: "en",
    now,
    viewer: fx.viewer,
    names: [],
    processes: [],
    clientKeys: [],
    catalog: {
      claude: [{ id: "claude-opus-4-6", label: "Opus 4.6" }],
    },
  };

  // All 54 normal ops: checkpoint + 53 moved ops (every op in main.mbt:120-124)
  const cases: Array<{ label: string; ask: Record<string, unknown>; statusOnly?: boolean }> = [
    { label: "checkpoint (passive)", ask: { id: 1, op: "checkpoint", args: {} } },
    { label: "checkpoint (hard)", ask: { id: 2, op: "checkpoint", args: { hard: true } } },
    { label: "job", ask: { id: 3, op: "job", args: { id: fx.jobId } } },
    { label: "jobLog", ask: { id: 4, op: "jobLog", args: { id: fx.jobId, lines: 10 } } },
    { label: "historyPendingCard", ask: { id: 5, op: "historyPendingCard", args: { thread: fx.threadId } } },
    { label: "statePendingCard", ask: { id: 6, op: "statePendingCard", args: { thread: fx.threadId } } },
    { label: "deliveryCardState", ask: { id: 7, op: "deliveryCardState", args: { thread: fx.threadId, n: 2 } } },
    { label: "reviewPendingCard", ask: { id: 8, op: "reviewPendingCard", args: { thread: fx.threadId } } },
    {
      label: "stateQuestion",
      ask: { id: 9, op: "stateQuestion", args: { key: fx.sessionKey, ts: "1795580002.000001", threads: [fx.threadId] } },
    },
    { label: "pendingDeliveries", ask: { id: 10, op: "pendingDeliveries", args: { key: fx.sessionKey } } },
    { label: "latestMessages", ask: { id: 11, op: "latestMessages", args: { thread: fx.threadId, limit: 10 } } },
    { label: "chatHistoryMessages", ask: { id: 12, op: "chatHistoryMessages", args: { thread: fx.threadId, limit: 10 } } },
    { label: "openedChatSaid", ask: { id: 13, op: "openedChatSaid", args: { thread: fx.threadId } } },
    { label: "widgetState", ask: { id: 14, op: "widgetState", args: { thread: fx.threadId } } },
    { label: "transcriptFile", ask: { id: 15, op: "transcriptFile", args: { key: fx.sessionKey } } },
    { label: "memory", ask: { id: 16, op: "memory", args: {} } },
    {
      label: "machineSessions",
      ask: { id: 17, op: "machineSessions", args: { roots: { claude: fx.dataDir, codex: fx.dataDir } } },
    },
    {
      label: "machineSession",
      ask: {
        id: 18,
        op: "machineSession",
        args: { runtime: "claude", id: "missing-id", roots: { claude: fx.dataDir, codex: fx.dataDir } },
      },
    },
    { label: "sessionsAtWork", ask: { id: 19, op: "sessionsAtWork", args: { keys: [fx.sessionKey] } } },
    { label: "policyChecks", ask: { id: 20, op: "policyChecks", args: { limit: 10 } } },
    { label: "recentConnectPeople", ask: { id: 21, op: "recentConnectPeople", args: { connect: "c1" } } },
    { label: "usageTurns", ask: { id: 22, op: "usageTurns", args: { key: fx.sessionKey } } },
    { label: "usageCalls", ask: { id: 23, op: "usageCalls", args: { key: fx.sessionKey } } },
    { label: "outflowMessages", ask: { id: 24, op: "outflowMessages", args: { thread: fx.threadId } } },
    { label: "archiveLook", ask: { id: 25, op: "archiveLook", args: { thread: fx.threadId } } },
    { label: "recentChatList", ask: { id: 26, op: "recentChatList", args: { limit: 10 } } },
    { label: "searchChatList", ask: { id: 27, op: "searchChatList", args: { query: "alpha", limit: 10 } } },
    { label: "threadList", ask: { id: 28, op: "threadList", args: {} } },
    { label: "sharedOf", ask: { id: 29, op: "sharedOf", args: {} } },
    { label: "sharedChats", ask: { id: 30, op: "sharedChats", args: {} } },
    { label: "chatMarks", ask: { id: 31, op: "chatMarks", args: {} } },
    { label: "entries", ask: { id: 32, op: "entries", args: { thread: String(fx.threadId), params: {} } } },
    { label: "letters", ask: { id: 33, op: "letters", args: { thread: String(fx.threadId), params: {} } } },
    { label: "summary", ask: { id: 34, op: "summary", args: { key: fx.sessionKey } } },
    { label: "sessions", ask: { id: 35, op: "sessions", args: {} } },
    { label: "session", ask: { id: 36, op: "session", args: { key: fx.sessionKey } } },
    { label: "threads", ask: { id: 37, op: "threads", args: {} } },
    { label: "thread", ask: { id: 38, op: "thread", args: { id: String(fx.threadId) } } },
    { label: "turnNotices", ask: { id: 39, op: "turnNotices", args: { keys: [fx.sessionKey] } } },
    { label: "saidNotices", ask: { id: 40, op: "saidNotices", args: { keys: [fx.sessionKey] } } },
    { label: "chats", ask: { id: 41, op: "chats", args: {} } },
    { label: "chatRows", ask: { id: 42, op: "chatRows", args: { ids: [fx.sessionKey] } } },
    { label: "outflowChats", ask: { id: 43, op: "outflowChats", args: {} } },
    { label: "openJobs", ask: { id: 44, op: "openJobs", args: {} } },
    { label: "resourceChats", ask: { id: 45, op: "resourceChats", args: { kind: "device", id: "dev-1" } } },
    { label: "usage", ask: { id: 46, op: "usage", args: { params: {} } } },
    { label: "outflowUsage", ask: { id: 47, op: "outflowUsage", args: {} } },
    { label: "timeline", ask: { id: 48, op: "timeline", args: { key: fx.sessionKey, params: {} } } },
    { label: "transcriptState", ask: { id: 49, op: "transcriptState", args: { key: fx.sessionKey } } },
    {
      label: "tailRead",
      ask: {
        id: 50,
        op: "tailRead",
        args: { runtime: "claude", state: { path: fx.transcriptPath } },
      },
    },
    { label: "sessionPlace", ask: { id: 51, op: "sessionPlace", args: { key: fx.sessionKey } } },
    { label: "internalCardEditPage", ask: { id: 52, op: "internalCardEditPage", args: { thread: fx.threadId, n: 1 } } },
    { label: "internalCardMessagePage", ask: { id: 53, op: "internalCardMessagePage", args: { thread: fx.threadId, n: 1 } } },
    {
      label: "internalMeshControl",
      ask: { id: 54, op: "internalMeshControl", args: { kind: "announcements", scope: "ws1", nodes: ["node-a"] } },
    },
    // `changed` across all 4 valid sub-lists + invalid op + missing op
    { label: "changed(chats)", ask: { id: 55, op: "changed", args: { op: "chats", args: {}, held: {} } } },
    { label: "changed(sharedChats)", ask: { id: 56, op: "changed", args: { op: "sharedChats", args: {}, held: {} } } },
    { label: "changed(sessions)", ask: { id: 57, op: "changed", args: { op: "sessions", args: {}, held: {} } } },
    { label: "changed(threads)", ask: { id: 58, op: "changed", args: { op: "threads", args: {}, held: {} } } },
    { label: "changed(invalid op)", ask: { id: 59, op: "changed", args: { op: "threadList", args: {}, held: {} } } },
    { label: "changed(non-string op)", ask: { id: 60, op: "changed", args: { op: 123, args: {}, held: {} } } },
    // Refused (400 / 404) & 500 error parity
    {
      label: "Refused 400 (entries bad paging)",
      ask: { id: 61, op: "entries", args: { thread: String(fx.threadId), params: { after: "nope" } } },
    },
    {
      label: "Refused 404 (session missing)",
      ask: { id: 62, op: "session", args: { key: "no-such-session" } },
    },
    {
      label: "500 unknown op",
      ask: { id: 63, op: "noSuchOp", args: {} },
    },
    {
      label: "400 missing op",
      ask: { id: 64, args: {} },
    },
  ];

  // Verify every single one of the 54 ops is represented in `cases`
  const opsCovered = new Set(cases.map((c) => String(c.ask.op ?? "")).filter(Boolean));
  assert.equal(opsCovered.size, 55, "expected 54 real ops + 1 unknown op test");

  for (const c of cases) {
    const payload = { ...baseAsk, ...c.ask };
    // For tailRead, each copy reads its own transcript path
    if (c.ask.op === "tailRead") {
      const mbPayload = {
        ...payload,
        args: { runtime: "claude", state: { path: join(mbDir, "transcripts", "s1.jsonl") } },
      };
      const pionPayload = {
        ...payload,
        args: { runtime: "claude", state: { path: join(pionDir, "transcripts", "s1.jsonl") } },
      };
      const [mr, pr] = await Promise.all([mb.ask(mbPayload), pion.ask(pionPayload)]);
      assert.equal(pr.head.status, mr.head.status, `${c.label}: status mismatch`);
      assert.notEqual(pr.body, null, `${c.label}: expected framed body`);
      const mObj = JSON.parse(mr.body!);
      const pObj = JSON.parse(pr.body!);
      // Normalize path field which points to each engine's independent copy
      const norm = (x: unknown) => JSON.parse(JSON.stringify(x).replaceAll(mbDir, "<DIR>").replaceAll(pionDir, "<DIR>"));
      assert.deepEqual(norm(pObj), norm(mObj), `${c.label}: body mismatch`);
      continue;
    }
    const [mr, pr] = await Promise.all([mb.ask(payload), pion.ask(payload)]);
    assert.equal(pr.head.id, mr.head.id, `${c.label}: id mismatch`);
    assert.equal(pr.head.status, mr.head.status, `${c.label}: status mismatch (${pr.headRaw} vs ${mr.headRaw})`);
    assert.equal(pr.head.prepareUpJobs, mr.head.prepareUpJobs, `${c.label}: prepareUpJobs mismatch`);
    assert.equal(
      pr.head.prepareWorkspaceUpJobs,
      mr.head.prepareWorkspaceUpJobs,
      `${c.label}: prepareWorkspaceUpJobs mismatch`,
    );
    if (mr.body !== null) {
      assert.notEqual(pr.body, null, `${c.label}: expected framed body`);
      // Normalize directory paths where ops echo dataDir/cwd/transcript path
      const norm = (s: string) =>
        JSON.parse(s.replaceAll(mbDir, "<DIR>").replaceAll(pionDir, "<DIR>"));
      assert.deepEqual(norm(pr.body!), norm(mr.body!), `${c.label}: body mismatch`);
    } else {
      assert.equal(pr.body, null, `${c.label}: unexpected body on error`);
      const stripMbLoc = (e: unknown) =>
        typeof e === "string" ? e.replace(/^src\/[^\s]+ FAILED:\s*/, "") : e;
      assert.equal(stripMbLoc(pr.head.error), stripMbLoc(mr.head.error), `${c.label}: error message mismatch`);
    }
  }

  // U+2028 / U+2029 in string id: header line MUST escape them as \u2028 / \u2029, and `bytes` MUST be last.
  const sepId = "id-\u2028-\u2029-end";
  const [mSep, pSep] = await Promise.all([
    mb.ask({ ...baseAsk, id: sepId, op: "threadList", args: {} }),
    pion.ask({ ...baseAsk, id: sepId, op: "threadList", args: {} }),
  ]);
  assert.ok(!pSep.headRaw.includes("\u2028") && !pSep.headRaw.includes("\u2029"), "header must escape U+2028/U+2029");
  assert.ok(pSep.headRaw.includes("\\u2028") && pSep.headRaw.includes("\\u2029"), "header must contain \\u2028/\\u2029");
  assert.equal(Object.keys(pSep.head).at(-1), "bytes", "bytes must be the last header field");
  assert.equal(pSep.headRaw, mSep.headRaw, "framed header line mismatch for U+2028/U+2029 id");
  assert.equal(pSep.body, mSep.body, "framed body mismatch for U+2028/U+2029 id");

  // Lone surrogate escape in incoming ask line MUST be rejected with 400 by both engines.
  const loneAsk = '{"id":99,"op":"threadList","x":"\\ud800"}';
  const [mLone, pLone] = await Promise.all([mb.askRaw(loneAsk), pion.askRaw(loneAsk)]);
  assert.equal(mLone.head.status, 400);
  assert.equal(pLone.head.status, 400);
  assert.equal(pLone.head.id, null);
  assert.equal(pLone.body, null);

  // Catalog persistence across an error: send new catalog on an erroring op, verify next op still sees it.
  const [mErrCat, pErrCat] = await Promise.all([
    mb.ask({
      ...baseAsk,
      id: 100,
      op: "session",
      args: { key: "missing-for-catalog" },
      catalog: { claude: [{ id: "claude-opus-4-6", label: "Persisted Opus" }] },
    }),
    pion.ask({
      ...baseAsk,
      id: 100,
      op: "session",
      args: { key: "missing-for-catalog" },
      catalog: { claude: [{ id: "claude-opus-4-6", label: "Persisted Opus" }] },
    }),
  ]);
  assert.equal(pErrCat.head.status, 404);
  assert.equal(mErrCat.head.status, 404);
  // Follow-up read WITHOUT catalog field: both engines must still agree using the retained catalog.
  const { catalog: _drop, ...noCatAsk } = baseAsk;
  const [mAfterCat, pAfterCat] = await Promise.all([
    mb.ask({ ...noCatAsk, id: 101, op: "sessions", args: { viewer: fx.viewer } }),
    pion.ask({ ...noCatAsk, id: 101, op: "sessions", args: { viewer: fx.viewer } }),
  ]);
  assert.equal(pAfterCat.head.status, mAfterCat.head.status);
  assert.notEqual(
    pAfterCat.body,
    null,
    `expected 200 body for sessions after retained catalog, got ${JSON.stringify(pAfterCat.head)}`,
  );
  assert.deepEqual(
    JSON.parse(pAfterCat.body!.replaceAll(pionDir, "<DIR>")),
    JSON.parse(mAfterCat.body!.replaceAll(mbDir, "<DIR>")),
    "retained catalog mismatch after error",
  );

  // TranscriptCache reuse across append, truncate, and zstd compression
  const at2 = "2026-11-25T00:01:00.000Z";
  const extraLine =
    JSON.stringify({
      type: "assistant",
      timestamp: at2,
      message: { id: "m2", content: [{ type: "text", text: "appended turn" }] },
    }) + "\n";
  appendFileSync(join(mbDir, "transcripts", "s1.jsonl"), extraLine);
  appendFileSync(join(pionDir, "transcripts", "s1.jsonl"), extraLine);
  const [mApp, pApp] = await Promise.all([
    mb.ask({ ...noCatAsk, id: 102, op: "timeline", args: { key: fx.sessionKey, viewer: fx.viewer } }),
    pion.ask({ ...noCatAsk, id: 102, op: "timeline", args: { key: fx.sessionKey, viewer: fx.viewer } }),
  ]);
  assert.notEqual(pApp.body, null, "expected 200 body for timeline after append");
  assert.deepEqual(JSON.parse(pApp.body!), JSON.parse(mApp.body!), "timeline parity after append");

  // Truncate/rewrite shorter
  const shortLine =
    JSON.stringify({ type: "user", timestamp: at2, message: { role: "user", content: "rewritten" } }) + "\n";
  writeFileSync(join(mbDir, "transcripts", "s1.jsonl"), shortLine);
  writeFileSync(join(pionDir, "transcripts", "s1.jsonl"), shortLine);
  const [mTrunc, pTrunc] = await Promise.all([
    mb.ask({ ...noCatAsk, id: 103, op: "timeline", args: { key: fx.sessionKey, viewer: fx.viewer } }),
    pion.ask({ ...noCatAsk, id: 103, op: "timeline", args: { key: fx.sessionKey, viewer: fx.viewer } }),
  ]);
  assert.notEqual(pTrunc.body, null, "expected 200 body for timeline after truncate");
  assert.deepEqual(JSON.parse(pTrunc.body!), JSON.parse(mTrunc.body!), "timeline parity after truncate");

  // Compressed .zst transcript via tailRead
  const zstBytes = zstdCompressSync(Buffer.from(shortLine, "utf8"));
  writeFileSync(join(mbDir, "transcripts", "s1.jsonl.zst"), zstBytes);
  writeFileSync(join(pionDir, "transcripts", "s1.jsonl.zst"), zstBytes);
  const [mZst, pZst] = await Promise.all([
    mb.ask({
      ...noCatAsk,
      id: 104,
      op: "tailRead",
      args: { runtime: "claude", state: { path: join(mbDir, "transcripts", "s1.jsonl.zst") } },
    }),
    pion.ask({
      ...noCatAsk,
      id: 104,
      op: "tailRead",
      args: { runtime: "claude", state: { path: join(pionDir, "transcripts", "s1.jsonl.zst") } },
    }),
  ]);
  assert.deepEqual(
    JSON.parse(pZst.body!.replaceAll(pionDir, "<DIR>")),
    JSON.parse(mZst.body!.replaceAll(mbDir, "<DIR>")),
    "tailRead parity on zst transcript",
  );
});

test("prepareUpJobs / prepareWorkspaceUpJobs reset between reads and never leak on error", async (t) => {
  const bins = resolveDualBinaries();
  if (!bins) return;

  const root = mkdtempSync(join(tmpdir(), "w7f-signals-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));

  const fx = buildStationFixture(root);
  // Drop legacy up-jobs index tables if present so openJobs triggers prepareWorkspaceUpJobs
  const mbDir = join(root, "mb");
  const pionDir = join(root, "pion");
  cpSync(fx.dataDir, mbDir, { recursive: true });
  cpSync(fx.dataDir, pionDir, { recursive: true });

  for (const dir of [mbDir, pionDir]) {
    const db = new DatabaseSync(join(dir, "stillfail.db"));
    db.exec("DROP TABLE IF EXISTS workspace_up_jobs; DROP TABLE IF EXISTS workspace_up_jobs_meta;");
    db.exec("DROP TABLE IF EXISTS session_up_jobs; DROP TABLE IF EXISTS session_up_jobs_meta;");
    db.close();
  }

  const mb = new RawDataClient(bins.mb, mbDir);
  const pion = new RawDataClient(bins.pion, pionDir);
  t.after(async () => {
    await Promise.all([mb.close(), pion.close()]);
  });
  await Promise.all([mb.ready(), pion.ready()]);

  const base = { lang: "en", now: 1795580000000, viewer: fx.viewer, names: [], processes: [], clientKeys: [] };

  // 1. openJobs may set prepareWorkspaceUpJobs — both engines must match
  const [m1, p1] = await Promise.all([
    mb.ask({ ...base, id: 1, op: "openJobs", args: {} }),
    pion.ask({ ...base, id: 1, op: "openJobs", args: {} }),
  ]);
  assert.equal(p1.head.prepareWorkspaceUpJobs, m1.head.prepareWorkspaceUpJobs);

  // 2. Subsequent unrelated read (threadList) MUST NOT carry stale prepareWorkspaceUpJobs / prepareUpJobs
  const [m2, p2] = await Promise.all([
    mb.ask({ ...base, id: 2, op: "threadList", args: {} }),
    pion.ask({ ...base, id: 2, op: "threadList", args: {} }),
  ]);
  assert.equal(p2.head.prepareWorkspaceUpJobs, undefined);
  assert.equal(p2.head.prepareUpJobs, undefined);
  assert.equal(m2.head.prepareWorkspaceUpJobs, undefined);

  // 3. Erroring read (session 404) MUST NOT leak signals
  const [m3, p3] = await Promise.all([
    mb.ask({ ...base, id: 3, op: "session", args: { key: "missing-s" } }),
    pion.ask({ ...base, id: 3, op: "session", args: { key: "missing-s" } }),
  ]);
  assert.equal(p3.head.status, 404);
  assert.equal(m3.head.status, 404);
  assert.equal(p3.head.prepareUpJobs, undefined);
  assert.equal(p3.head.prepareWorkspaceUpJobs, undefined);
});

test("dual-connection snapshot/write contention and checkpoint(hard) busy_timeout recovery", async (t) => {
  const bins = resolveDualBinaries();
  if (!bins) return;

  const root = mkdtempSync(join(tmpdir(), "w7f-contention-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));

  const fx = buildStationFixture(root);
  const pionDir = join(root, "pion");
  cpSync(fx.dataDir, pionDir, { recursive: true });
  const dbPath = join(pionDir, "stillfail.db");

  const pion = new RawDataClient(bins.pion, pionDir);
  t.after(() => pion.close());
  await pion.ready();

  // Fill WAL pages from an external writer while Pion serves concurrent reads
  const writer = new DatabaseSync(dbPath);
  t.after(() => writer.close());
  writer.exec("CREATE TABLE IF NOT EXISTS filler (v TEXT)");
  const ins = writer.prepare("INSERT INTO filler (v) VALUES (?)");
  for (let i = 0; i < 400; i++) ins.run("w".repeat(4000));

  // Hold a read snapshot on a third connection so hard checkpoint cannot truncate past it,
  // then verify busy_timeout is restored to 0 (non-blocking) for subsequent passive checkpoints.
  const holder = new DatabaseSync(dbPath, { readOnly: true });
  holder.exec("BEGIN");
  holder.prepare("SELECT COUNT(*) FROM filler").get();

  const hardWhileHeld = await pion.ask({ id: 1, op: "checkpoint", args: { hard: true } });
  assert.equal(hardWhileHeld.head.status, undefined);
  const hardRow = JSON.parse(hardWhileHeld.body!) as { busy: number; log: number; checkpointed: number };
  assert.equal(typeof hardRow.busy, "number");
  assert.equal(typeof hardRow.log, "number");
  assert.equal(typeof hardRow.checkpointed, "number");

  // Release holder and run passive checkpoint; must complete cleanly and checkpoint all frames
  holder.exec("COMMIT");
  holder.close();

  const passiveAfter = await pion.ask({ id: 2, op: "checkpoint", args: {} });
  assert.equal(passiveAfter.head.status, undefined);
  const passiveRow = JSON.parse(passiveAfter.body!) as { busy: number; log: number; checkpointed: number };
  assert.equal(passiveRow.busy, 0);
  assert.equal(passiveRow.checkpointed, passiveRow.log);

  // Regular read still works cleanly after checkpoint(hard)
  const listRes = await pion.ask({ id: 3, op: "threadList", args: {} });
  assert.equal(listRes.head.status, undefined);
  assert.ok(Array.isArray(JSON.parse(listRes.body!)));
});

test("Readers pool & OwnReader cold-start, cooldown, explicit override, hot-reload with LiveProgram.binary", async (t) => {
  const bins = resolveDualBinaries();
  if (!bins) return;

  const root = mkdtempSync(join(tmpdir(), "w7f-pool-switch-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const fx = buildStationFixture(root);

  let cfg: ReaderSelectConfig = { readers: { data: "pion" } };
  resetReaderSelectionStateForTest();
  t.after(() => resetReaderSelectionStateForTest());

  // 1. Cold-start Pion via Readers pool -> LiveProgram.binary === bins.pion
  const readers = new Readers(fx.dataDir, 1, undefined, 1, { readers: () => cfg });
  t.after(() => readers.close());
  const r1 = JSON.parse(await readers.read("threadList", {}, "en"));
  assert.ok(Array.isArray(r1));
  const live1 = MbProcess.live().filter((p) => p.args.includes(fx.dataDir));
  assert.ok(live1.length >= 1, "expected at least one live data reader");
  assert.equal(realpathSync(live1[0]!.binary!), bins.pion, "cold-start data reader must execute Pion binary");

  // 2. Hot-reload config from pion -> mb -> new spawn uses bins.mb
  cfg = { readers: { data: "mb" } };
  readers.retireMismatchedIdle();
  const r2 = JSON.parse(await readers.read("threadList", {}, "en"));
  assert.deepEqual(r2, r1);
  const live2 = MbProcess.live().filter((p) => p.args.includes(fx.dataDir) && realpathSync(p.binary) === bins.mb);
  assert.ok(live2.length >= 1, "hot-reloaded data reader must execute MB binary");

  // 3. Explicit mbReader override always wins over config=pion
  cfg = { readers: { data: "pion" } };
  const explicit = new Readers(fx.dataDir, 1, undefined, 1, { readers: () => cfg });
  explicit.mbReader = bins.mb;
  t.after(() => explicit.close());
  const r3 = JSON.parse(await explicit.read("threadList", {}, "en"));
  assert.deepEqual(r3, r1);
  const live3 = MbProcess.live().filter((p) => p.args.includes(fx.dataDir) && realpathSync(p.binary) === bins.mb);
  assert.ok(live3.length >= 1, "explicit mbReader override must win over config");

  // 4. Cooldown fallback when Pion probe fails -> falls back to MB cleanly
  resetReaderSelectionStateForTest();
  setPionProbeRunnerForTest(async () => null);
  try {
    const sel = await resolveReaderSelectionAsync("data", { config: { readers: { data: "pion" } } });
    assert.equal(sel.engine, "mb");
    assert.equal(sel.selection.fallback, true);
  } finally {
    setPionProbeRunnerForTest(null);
    resetReaderSelectionStateForTest();
  }

  // 5. OwnReader (standalone tailRead) switches cleanly between Pion and MB
  let ownCfg: ReaderSelectConfig = { readers: { data: "pion" } };
  const own = new OwnReader(() => ownCfg);
  t.after(() => own.close());
  const tPion = await own.tailRead("claude", { path: fx.transcriptPath });
  assert.ok(Array.isArray(tPion.entries) && tPion.entries.length >= 2);
  ownCfg = { readers: { data: "mb" } };
  const tMb = await own.tailRead("claude", { path: fx.transcriptPath });
  assert.deepEqual(tMb, tPion);
});

test("mixed-mode LiveHub: un-overridden Readers({ data: pion }) runs BIN_PION alongside real MB --sessions (BIN_MB)", async (t) => {
  const bins = resolveDualBinaries();
  if (!bins) return;

  const root = mkdtempSync(join(tmpdir(), "w7f-mixed-mode-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const fx = buildStationFixture(root);

  resetReaderSelectionStateForTest();
  t.after(() => resetReaderSelectionStateForTest());

  // Un-overridden Readers with data="pion" (never setting mbReader!)
  const readers = new Readers(fx.dataDir, 1, undefined, 1, { readers: () => ({ readers: { data: "pion" } }) });
  t.after(() => readers.close());

  // Real MB --sessions process running concurrently on the same data directory
  const sessionsSel = await resolveReaderSelectionAsync("sessions", { config: { readers: { data: "pion" } } });
  assert.equal(sessionsSel.engine, "mb", "sessions mode must remain on MB in Wave 7");
  assert.equal(realpathSync(sessionsSel.primaryBinary), bins.mb, "sessions selection must resolve to BIN_MB");

  const sessionsProc = spawn(sessionsSel.primaryBinary, ["--data", fx.dataDir, "--sessions"], {
    stdio: ["pipe", "pipe", "pipe"],
  });
  t.after(async () => {
    sessionsProc.stdin.end();
    await new Promise<void>((resolve) => {
      if (sessionsProc.exitCode !== null) return resolve();
      sessionsProc.once("exit", () => resolve());
    });
  });

  // Wait for MB --sessions ready line
  const sessionsReady = await new Promise<string>((resolve, reject) => {
    let buf = "";
    sessionsProc.stdout.on("data", (c: Buffer) => {
      buf += c.toString("utf8");
      const nl = buf.indexOf("\n");
      if (nl >= 0) resolve(buf.slice(0, nl));
    });
    sessionsProc.once("exit", (code) => reject(new Error(`--sessions exited early: ${code}`)));
  });
  assert.ok(sessionsReady.includes("ready"), `unexpected --sessions ready line: ${sessionsReady}`);

  // LiveHub delegates tailRead to un-overridden Pion Readers pool while MB --sessions is live
  const hub = new LiveHub(() => ({ runtime: "claude", paths: [fx.transcriptPath], current: true }));
  hub.tailRead = async (runtime, state) =>
    JSON.parse(await readers.read("tailRead", { runtime, state }, "en", { told: true }));
  t.after(() => hub.close());

  const seen: unknown[] = [];
  hub.subscribe("s-alpha", 0, null, (m) => {
    if (m.type === "timeline") seen.push(...m.entries);
  });
  await hub.idle();
  await hub.turnEnded("s-alpha");
  assert.ok(seen.length >= 2, `expected timeline entries from LiveHub via Pion Readers, got ${seen.length}`);

  // Prove `--data` actually executed BIN_PION (not BIN_MB) while `--sessions` executed BIN_MB
  const live = MbProcess.live().filter((p) => p.args.includes(fx.dataDir));
  assert.ok(live.length >= 1, "expected live Readers program");
  assert.equal(realpathSync(live[0]!.binary), bins.pion, "--data must have executed BIN_PION");
  assert.equal(realpathSync(sessionsSel.primaryBinary), bins.mb, "--sessions must have executed BIN_MB");
});
