// Dual-engine MB vs Pion `--data <dir>` parity, pool/OwnReader switching, concurrency,
// and mixed-mode LiveHub (--data=pion + --sessions=mb) verification (zero setTimeout sleeps).

import assert from "node:assert/strict";
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import {
  appendFileSync,
  chmodSync,
  cpSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, sep } from "node:path";
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
import { installOutflowChatIndex, outflowChatIndexStep } from "./reference/backfill/outflow-index.ts";
import { installRecentChatIndex, stepRecentChatIndex } from "./reference/chat-list/chat-list-index.ts";

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
    this.#proc = spawn(binary, ["--data", dataDir, "--sep", sep], {
      stdio: ["pipe", "pipe", "pipe"],
      env: { ...process.env, HOME: dataDir },
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

type FixtureViewer = {
  email: string;
  home: boolean;
  workspace: string | null;
  slack: string[];
  workspaces: string[];
  roles: Record<string, string>;
};

/** Build a rich deterministic station fixture exercising all 54 ops, policyChecks, usage_15m, and locatable transcripts. */
function buildStationFixture(root: string): {
  dataDir: string;
  transcriptRel: string;
  transcriptPath: string;
  threadId: number;
  sessionKey: string;
  jobId: string;
  viewer: FixtureViewer;
} {
  const dataDir = join(root, "source");
  mkdirSync(join(dataDir, "archive"), { recursive: true });
  mkdirSync(join(dataDir, "memory", "skills", "custom-skill"), { recursive: true });
  mkdirSync(join(dataDir, "jobs"), { recursive: true });

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
      agentHome: "memory",
      profiles: [{ id: "own", home: "homes/own" }],
      workspaces: [{ id: "ws1", name: "Workspace One" }],
      connects: [{ id: "c1", kind: "slack", team: "T1", workspace: "ws1" }],
    }),
    "utf8",
  );

  const jobId = "job-1";
  const jobLogPath = join(dataDir, "jobs", "job-1.log");
  writeFileSync(jobLogPath, "line 1\nline 2\nline 3\n", "utf8");

  // Locatable Claude transcript matching mb-reader-timeline.test.ts:85 (`transcripts/claude/<slug>/<rtId>.jsonl`)
  const transcriptRel = join("transcripts", "claude", "-w-alpha", "rt-alpha.jsonl");
  const transcriptPath = join(dataDir, transcriptRel);
  mkdirSync(dirname(transcriptPath), { recursive: true });
  const at = "2026-11-25T00:00:00.000Z";
  const claudeTranscriptBody =
    [
      JSON.stringify({ type: "user", cwd: "/w/alpha", timestamp: at, message: { role: "user", content: "hello agent" } }),
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
    ].join("\n") + "\n";
  writeFileSync(transcriptPath, claudeTranscriptBody, "utf8");
  // Also seed $HOME/.claude/projects/-w-alpha/rt-alpha.jsonl so `machineSession` returns 200
  const machineTranscriptPath = join(dataDir, ".claude", "projects", "-w-alpha", "rt-alpha.jsonl");
  mkdirSync(dirname(machineTranscriptPath), { recursive: true });
  writeFileSync(machineTranscriptPath, claudeTranscriptBody, "utf8");

  const store = Store.open(join(dataDir, "stillfail.db"), join(dataDir, "archive"));
  const db = store.db;
  const sessionKey = "s-alpha";
  const now = 1795580000000;

  const threadId = store.openThread("chat", "CHAT", "1795580000.000001", "Alpha Chat", "alice@example.com").id;
  db.prepare(
    `UPDATE threads SET created_at = ?, home = ?, project = 'monoid', project_locked = 1, tags = '["backend","ops"]' WHERE id = ?`,
  ).run(now - 60000, sessionKey, threadId);

  store.insertSession({
    key: sessionKey,
    connect: "chat",
    scope: "thread",
    title: "Alpha Chat",
    createdBy: "alice@example.com",
    runtime: "claude",
    profile: "own",
    model: "claude-opus-4-6",
    workspace: "/w/alpha",
    token: "tok-alpha",
    createdAt: now - 60000,
    lastActiveAt: now - 1000,
    ws: null,
  } as Parameters<Store["insertSession"]>[0]);
  store.setRuntimeSessionId(sessionKey, "rt-alpha");
  store.ranIn(sessionKey, "rt-alpha", "own");
  store.joinThread(threadId, sessionKey, "chat");
  db.prepare(`UPDATE thread_sessions SET joined_at = ? WHERE thread = ? AND session = ?`).run(
    now - 60000,
    threadId,
    sessionKey,
  );

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

  // Seed usage (1M input + 1M output on claude-opus-4-6) via store.recordUsage so `usage` computes non-zero cost
  store.recordUsage(
    `/t/${sessionKey}`,
    { session: sessionKey, offset: 1, model: "claude-opus-4-6" },
    "claude",
    [
      [
        {
          id: "call1",
          at: now - 60000,
          model: "claude-opus-4-6",
          subagent: false,
          fast: false,
          input: 1000000,
          cacheRead: 0,
          cacheWrite: 0,
          cacheWriteLong: 0,
          output: 1000000,
          calls: 1,
          context: null,
          window: null,
        },
        { turn: null, thread: threadId, person: "alice@example.com", profile: "own" },
      ],
    ] as never,
  );

  // Seed decision_checks for raw-wire policyChecks parity: numeric key order ["10","2","1"]
  // and created_at = 9007199254740993 (> 2^53). (Lone-surrogate key "\ud800" vs "\ufffd" is
  // tested separately on Pion below because MB's stdout UTF-8 encoder rejects unescaped surrogates.)
  db.exec(`CREATE INDEX IF NOT EXISTS decision_checks_lately ON decision_checks (created_at, id)`);
  db.exec(`CREATE INDEX IF NOT EXISTS decision_checks_session ON decision_checks (session, id)`);
  const insDec = db.prepare(
    `INSERT INTO decision_checks (session, created_at, result) VALUES (?, ?, ?)`,
  );
  // Note: policyChecks reverses ORDER BY created_at, id -> latest first, so insert in reverse order
  // so picks order becomes ["10", "2", "1"].
  insDec.run("dc-1", 300, '{"result":{"selected":"1"},"accepted":true}');
  insDec.run("dc-2", 400, '{"result":{"selected":"2"},"accepted":false}');
  insDec.run("dc-10", 9007199254740993n, '{"result":{"selected":"10"},"accepted":true}');

  // Mark cc_index ready for sessionKey so `session` returns 200 (not 503 pending)
  db.prepare(
    `INSERT OR REPLACE INTO cc_sessions (session, scan_after, scan_end, complete) VALUES (?, NULL, NULL, 1)`,
  ).run(sessionKey);

  // Build global recent_chat & outflow indexes so `recentChatList` and `outflowChats` return 200
  installRecentChatIndex(db);
  while (!stepRecentChatIndex(db).done) {}
  installOutflowChatIndex(db);
  while (!outflowChatIndexStep(db, "").done) {}

  store.close();

  return {
    dataDir,
    transcriptRel,
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

test("all 54 ops (with args.viewer) + raw policyChecks + numeric/separator frame ids + catalog + TranscriptCache parity", async (t) => {
  const bins = resolveDualBinaries();
  if (!bins) return;

  const root = mkdtempSync(join(tmpdir(), "w7f-54ops-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));

  const fx = buildStationFixture(root);
  const mbDir = join(root, "mb-copy");
  const pionDir = join(root, "pion-copy");
  cpSync(fx.dataDir, mbDir, { recursive: true, preserveTimestamps: true });
  cpSync(fx.dataDir, pionDir, { recursive: true, preserveTimestamps: true });

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
    names: [],
    processes: [],
    clientKeys: [],
  };

  // All 54 normal ops (checkpoint + 53 moved ops), passing `viewer: fx.viewer` INSIDE `args`.
  const okCases: Array<{ label: string; op: string; args: Record<string, unknown>; nonEmptyList?: boolean }> = [
    { label: "checkpoint (passive)", op: "checkpoint", args: {} },
    { label: "checkpoint (hard)", op: "checkpoint", args: { hard: true } },
    { label: "job", op: "job", args: { id: fx.jobId } },
    { label: "jobLog", op: "jobLog", args: { id: fx.jobId, lines: "10" } },
    { label: "historyPendingCard", op: "historyPendingCard", args: { thread: fx.threadId } },
    { label: "statePendingCard", op: "statePendingCard", args: { thread: fx.threadId } },
    { label: "deliveryCardState", op: "deliveryCardState", args: { thread: fx.threadId, n: 2 } },
    { label: "reviewPendingCard", op: "reviewPendingCard", args: { thread: fx.threadId } },
    {
      label: "stateQuestion",
      op: "stateQuestion",
      args: { key: fx.sessionKey, ts: "1795580002.000001", threads: [fx.threadId] },
    },
    { label: "pendingDeliveries", op: "pendingDeliveries", args: { key: fx.sessionKey } },
    { label: "latestMessages", op: "latestMessages", args: { thread: fx.threadId, limit: 10 } },
    { label: "chatHistoryMessages", op: "chatHistoryMessages", args: { thread: fx.threadId, limit: 10 } },
    { label: "openedChatSaid", op: "openedChatSaid", args: { thread: fx.threadId } },
    { label: "widgetState", op: "widgetState", args: { key: fx.sessionKey, path: "" } },
    { label: "transcriptFile", op: "transcriptFile", args: { key: fx.sessionKey } },
    { label: "memory", op: "memory", args: {} },
    { label: "machineSessions", op: "machineSessions", args: {} },
    {
      label: "machineSession",
      op: "machineSession",
      args: { lang: "en", runtime: "claude", id: "rt-alpha" },
    },
    { label: "sessionsAtWork", op: "sessionsAtWork", args: { keys: [fx.sessionKey] } },
    { label: "policyChecks", op: "policyChecks", args: { since: 0, viewer: fx.viewer } },
    { label: "recentConnectPeople", op: "recentConnectPeople", args: { connect: "c1", limit: 10 } },
    { label: "usageTurns", op: "usageTurns", args: { session: fx.sessionKey, from: 0, until: now } },
    {
      label: "usageCalls",
      op: "usageCalls",
      args: { session: fx.sessionKey, from: "0", to: String(now), beforeAt: String(now), beforeSeq: "0", limit: 10, viewer: fx.viewer },
    },
    { label: "outflowMessages", op: "outflowMessages", args: { thread: fx.threadId } },
    { label: "archiveLook", op: "archiveLook", args: { now, after: 86400000, slackAfter: 86400000 } },
    { label: "recentChatList", op: "recentChatList", args: { ws: null, home: null, limit: 10 } },
    { label: "searchChatList", op: "searchChatList", args: { ws: null, home: null, query: "alpha", limit: 10 } },
    { label: "threadList", op: "threadList", args: {} },
    { label: "sharedOf", op: "sharedOf", args: { sessions: [fx.sessionKey], threads: [fx.threadId] } },
    {
      label: "sharedChats",
      op: "sharedChats",
      args: { viewer: fx.viewer, sessions: [fx.sessionKey], threads: [fx.threadId] },
      nonEmptyList: true,
    },
    { label: "chatMarks", op: "chatMarks", args: { viewer: fx.viewer } },
    { label: "entries", op: "entries", args: { thread: String(fx.threadId), params: {}, viewer: fx.viewer } },
    { label: "letters", op: "letters", args: { thread: String(fx.threadId), params: {}, viewer: fx.viewer } },
    { label: "summary", op: "summary", args: { key: fx.sessionKey, viewer: fx.viewer } },
    {
      label: "sessions",
      op: "sessions",
      args: { connect: null, archived: false, viewer: fx.viewer, lang: "en" },
      nonEmptyList: true,
    },
    { label: "session", op: "session", args: { key: fx.sessionKey, viewer: fx.viewer } },
    {
      label: "threads",
      op: "threads",
      args: { viewer: fx.viewer, session: null, lang: "en" },
      nonEmptyList: true,
    },
    { label: "thread", op: "thread", args: { id: String(fx.threadId), viewer: fx.viewer } },
    { label: "turnNotices", op: "turnNotices", args: { keys: [fx.sessionKey], viewer: fx.viewer } },
    { label: "saidNotices", op: "saidNotices", args: { keys: [fx.sessionKey], viewer: fx.viewer } },
    { label: "chats", op: "chats", args: { viewer: fx.viewer, archived: false }, nonEmptyList: true },
    { label: "chatRows", op: "chatRows", args: { ids: [fx.sessionKey], viewer: fx.viewer } },
    { label: "outflowChats", op: "outflowChats", args: { viewer: fx.viewer } },
    { label: "openJobs", op: "openJobs", args: { viewer: fx.viewer } },
    { label: "resourceChats", op: "resourceChats", args: { kind: "device", id: "dev-1", viewer: fx.viewer } },
    { label: "usage", op: "usage", args: { from: now - 86400000, to: now, tz: 0, viewer: fx.viewer } },
    { label: "outflowUsage", op: "outflowUsage", args: { from: now - 86400000, to: now, tz: 0, viewer: fx.viewer } },
    { label: "timeline", op: "timeline", args: { key: fx.sessionKey, viewer: fx.viewer } },
    { label: "transcriptState", op: "transcriptState", args: { key: fx.sessionKey } },
    { label: "tailRead", op: "tailRead", args: { runtime: "claude", state: { path: fx.transcriptPath } } },
    { label: "sessionPlace", op: "sessionPlace", args: { key: fx.sessionKey, viewer: fx.viewer } },
    { label: "internalCardEditPage", op: "internalCardEditPage", args: { thread: fx.threadId, target: 1 } },
    { label: "internalCardMessagePage", op: "internalCardMessagePage", args: { thread: fx.threadId, target: 1 } },
    {
      label: "internalMeshControl",
      op: "internalMeshControl",
      args: { kind: "announcements", scope: "ws1", nodes: ["node-a"] },
    },
    // `changed` across all 4 valid sub-lists with args.viewer
    {
      label: "changed(chats)",
      op: "changed",
      args: { op: "chats", args: { viewer: fx.viewer, archived: false }, id: "id", held: {} },
      nonEmptyList: true,
    },
    {
      label: "changed(sharedChats)",
      op: "changed",
      args: { op: "sharedChats", args: { viewer: fx.viewer, sessions: null, threads: null }, id: "id", held: {} },
      nonEmptyList: true,
    },
    {
      label: "changed(sessions)",
      op: "changed",
      args: { op: "sessions", args: { connect: null, archived: false, viewer: fx.viewer, lang: "en" }, id: "key", held: {} },
      nonEmptyList: true,
    },
    {
      label: "changed(threads)",
      op: "changed",
      args: { op: "threads", args: { viewer: fx.viewer, session: null, lang: "en" }, id: "id", held: {} },
      nonEmptyList: true,
    },
  ];

  // Verify all 54 real ops are covered in okCases
  assert.equal(new Set(okCases.map((c) => c.op)).size, 54, "expected all 54 real ops in okCases");

  let nextId = 1;
  for (const c of okCases) {
    const id = nextId++;
    const payload = { ...baseAsk, id, op: c.op, args: { viewer: fx.viewer, ...c.args } };
    let mr: { headRaw: string; head: Record<string, unknown>; body: string | null };
    let pr: { headRaw: string; head: Record<string, unknown>; body: string | null };
    if (c.op === "tailRead") {
      [mr, pr] = await Promise.all([
        mb.ask({
          ...payload,
          args: { runtime: "claude", state: { path: join(mbDir, fx.transcriptRel) } },
        }),
        pion.ask({
          ...payload,
          args: { runtime: "claude", state: { path: join(pionDir, fx.transcriptRel) } },
        }),
      ]);
    } else if (c.op === "machineSessions" || c.op === "machineSession") {
      [mr, pr] = await Promise.all([
        mb.ask({
          ...payload,
          args: {
            ...payload.args,
            roots: { claude: join(mbDir, ".claude", "projects"), codex: join(mbDir, "codex-home") },
          },
        }),
        pion.ask({
          ...payload,
          args: {
            ...payload.args,
            roots: { claude: join(pionDir, ".claude", "projects"), codex: join(pionDir, "codex-home") },
          },
        }),
      ]);
    } else if (c.op === "sessionPlace") {
      [mr, pr] = await Promise.all([
        mb.ask({
          ...payload,
          args: { ...payload.args, path: join(mbDir, "memory", "MEMORY.md") },
        }),
        pion.ask({
          ...payload,
          args: { ...payload.args, path: join(pionDir, "memory", "MEMORY.md") },
        }),
      ]);
    } else {
      [mr, pr] = await Promise.all([mb.ask(payload), pion.ask(payload)]);
    }
    assert.equal(pr.head.id, id, `${c.label}: id mismatch`);
    assert.equal(mr.head.status, undefined, `${c.label}: MB unexpected status ${mr.headRaw}`);
    assert.equal(pr.head.status, undefined, `${c.label}: Pion unexpected status ${pr.headRaw}`);
    assert.notEqual(pr.body, null, `${c.label}: expected framed body`);
    assert.notEqual(mr.body, null, `${c.label}: expected MB framed body`);

    // Raw-byte wire parity for policyChecks (numeric key order ["10","2","1"] and at=9007199254740993)
    if (c.op === "policyChecks") {
      assert.equal(pr.body, mr.body, "policyChecks raw wire body mismatch");
      const i10 = pr.body!.indexOf('"10":');
      const i2 = pr.body!.indexOf('"2":');
      const i1 = pr.body!.indexOf('"1":');
      assert.ok(i10 >= 0 && i2 > i10 && i1 > i2, `policyChecks numeric key order wrong: ${pr.body}`);
      assert.ok(pr.body!.includes("9007199254740993"), `policyChecks lost >2^53 precision: ${pr.body}`);
      // Also verify Pion preserves distinct lone-surrogate "\ud800" vs "\ufffd" keys losslessly on wire
      const pionDb = new DatabaseSync(join(pionDir, "stillfail.db"));
      pionDb
        .prepare(`INSERT INTO decision_checks (session, created_at, result) VALUES (?, ?, ?)`)
        .run("dc-fffd", 100, '{"result":{"selected":"\\ufffd"},"accepted":true}');
      pionDb
        .prepare(`INSERT INTO decision_checks (session, created_at, result) VALUES (?, ?, ?)`)
        .run("dc-lone", 200, '{"result":{"selected":"\\ud800"},"accepted":false}');
      pionDb.close();
      const prSurr = await pion.ask({ ...payload, id: nextId++ });
      assert.equal(prSurr.head.status, undefined, `policyChecks lone-surrogate failed: ${prSurr.headRaw}`);
      assert.ok(
        prSurr.body!.toLowerCase().includes("\\ud800") &&
          (prSurr.body!.includes("\ufffd") || prSurr.body!.toLowerCase().includes("\\ufffd")),
        `policyChecks must preserve distinct lone surrogate and U+FFFD keys: ${prSurr.body}`,
      );
      continue;
    }

    const norm = (s: string) => JSON.parse(s.replaceAll(mbDir, "<DIR>").replaceAll(pionDir, "<DIR>"));
    const pVal = norm(pr.body!);
    const mVal = norm(mr.body!);
    assert.deepEqual(pVal, mVal, `${c.label}: body mismatch`);

    if (c.nonEmptyList) {
      if (c.op === "changed") {
        const orderArr = (pVal as { order?: unknown[] }).order;
        const rowsArr = (pVal as { rows?: unknown[] }).rows;
        assert.ok(
          Array.isArray(orderArr) && orderArr.length > 0 && Array.isArray(rowsArr) && rowsArr.length > 0,
          `${c.label}: expected non-empty changed order/rows, got ${JSON.stringify(pVal)}`,
        );
      } else {
        const listArr = Array.isArray(pVal)
          ? pVal
          : (pVal as { chats?: unknown[]; sessions?: unknown[]; threads?: unknown[]; rows?: unknown[] }).chats ??
            (pVal as { sessions?: unknown[] }).sessions ??
            (pVal as { threads?: unknown[] }).threads ??
            (pVal as { rows?: unknown[] }).rows;
        assert.ok(Array.isArray(listArr) && listArr.length > 0, `${c.label}: expected non-empty list, got ${pr.body}`);
      }
    }
  }

  // Explicit error status assertions (400 / 404 / 500 / 400 + invalid changed)
  const errCases: Array<{ label: string; ask: Record<string, unknown>; expectedStatus: number }> = [
    {
      label: "Refused 400 (entries bad paging)",
      ask: { id: 201, op: "entries", args: { thread: String(fx.threadId), params: { after: "nope" }, viewer: fx.viewer } },
      expectedStatus: 400,
    },
    {
      label: "Refused 404 (session missing)",
      ask: { id: 202, op: "session", args: { key: "no-such-session", viewer: fx.viewer } },
      expectedStatus: 404,
    },
    {
      label: "500 unknown op",
      ask: { id: 203, op: "noSuchOp", args: {} },
      expectedStatus: 500,
    },
    {
      label: "400 missing op",
      ask: { id: 204, args: {} },
      expectedStatus: 400,
    },
    {
      label: "changed(invalid op) 500",
      ask: { id: 205, op: "changed", args: { op: "threadList", args: {}, held: {} } },
      expectedStatus: 500,
    },
    {
      label: "changed(non-string op) 500",
      ask: { id: 206, op: "changed", args: { op: 123, args: {}, held: {} } },
      expectedStatus: 500,
    },
  ];
  for (const ec of errCases) {
    const [mr, pr] = await Promise.all([mb.ask({ ...baseAsk, ...ec.ask }), pion.ask({ ...baseAsk, ...ec.ask })]);
    assert.equal(mr.head.status, ec.expectedStatus, `${ec.label}: MB status mismatch`);
    assert.equal(pr.head.status, ec.expectedStatus, `${ec.label}: Pion status mismatch`);
    assert.equal(pr.body, null, `${ec.label}: unexpected body on error`);
    const stripMbLoc = (e: unknown) =>
      typeof e === "string" ? e.replace(/^src\/[^\s]+ FAILED:\s*/, "") : e;
    assert.equal(stripMbLoc(pr.head.error), stripMbLoc(mr.head.error), `${ec.label}: error message mismatch`);
  }

  // Raw frame header parity for numeric IDs (0.00001, 100000000000000000000, 1e-7) and U+2028/U+2029 string id
  for (const rawId of ["0.00001", "100000000000000000000", "1e-7", '"id-\\u2028-\\u2029-end"']) {
    const rawAsk = `{"id":${rawId},"op":"threadList","args":{}}`;
    const [mRes, pRes] = await Promise.all([mb.askRaw(rawAsk), pion.askRaw(rawAsk)]);
    assert.equal(pRes.headRaw, mRes.headRaw, `raw header mismatch for id=${rawId}`);
    assert.equal(pRes.body, mRes.body, `raw body mismatch for id=${rawId}`);
    assert.equal(Object.keys(pRes.head).at(-1), "bytes", `bytes must be last for id=${rawId}`);
    assert.ok(!pRes.headRaw.includes("\u2028") && !pRes.headRaw.includes("\u2029"));
  }

  // Lone surrogate escape in incoming ask line MUST be rejected with 400 by both engines.
  const loneAsk = '{"id":299,"op":"threadList","x":"\\ud800"}';
  const [mLone, pLone] = await Promise.all([mb.askRaw(loneAsk), pion.askRaw(loneAsk)]);
  assert.equal(mLone.head.status, 400);
  assert.equal(pLone.head.status, 400);
  assert.equal(pLone.head.id, null);
  assert.equal(pLone.body, null);

  // Positive `catalog` persistence across an error:
  // 1) Read default usage cost (without custom catalog).
  const usageArgs = { from: now - 86400000, to: now, tz: 0, viewer: fx.viewer };
  const [mDefaultUsage, pDefaultUsage] = await Promise.all([
    mb.ask({ ...baseAsk, id: 300, op: "usage", args: usageArgs }),
    pion.ask({ ...baseAsk, id: 300, op: "usage", args: usageArgs }),
  ]);
  const defaultCost = (JSON.parse(pDefaultUsage.body!) as { rows?: Array<{ cost?: number }> }).rows?.[0]?.cost;
  assert.equal(
    defaultCost,
    (JSON.parse(mDefaultUsage.body!) as { rows?: Array<{ cost?: number }> }).rows?.[0]?.cost,
    "default usage cost mismatch",
  );
  assert.equal(typeof defaultCost, "number");

  // 2) Send a custom price table on an ERRORING op (404 session).
  const customCatalog = { "claude-opus-4-6": { cost: { input: 123, output: 456, cacheRead: 10 } } };
  const [mErrCat, pErrCat] = await Promise.all([
    mb.ask({
      ...baseAsk,
      id: 301,
      op: "session",
      args: { key: "missing-for-catalog", viewer: fx.viewer },
      catalog: customCatalog,
    }),
    pion.ask({
      ...baseAsk,
      id: 301,
      op: "session",
      args: { key: "missing-for-catalog", viewer: fx.viewer },
      catalog: customCatalog,
    }),
  ]);
  assert.equal(mErrCat.head.status, 404);
  assert.equal(pErrCat.head.status, 404);

  // 3) Follow-up `usage` WITHOUT catalog field: cost MUST reflect customCatalog (123 + 456 = 579 != defaultCost).
  const [mCustomUsage, pCustomUsage] = await Promise.all([
    mb.ask({ ...baseAsk, id: 302, op: "usage", args: usageArgs }),
    pion.ask({ ...baseAsk, id: 302, op: "usage", args: usageArgs }),
  ]);
  const pCustomCost = (JSON.parse(pCustomUsage.body!) as { rows?: Array<{ cost?: number }> }).rows?.[0]?.cost;
  const mCustomCost = (JSON.parse(mCustomUsage.body!) as { rows?: Array<{ cost?: number }> }).rows?.[0]?.cost;
  assert.equal(pCustomCost, mCustomCost, "custom catalog usage cost mismatch");
  assert.equal(pCustomCost, 579, `expected custom catalog cost 579 (1M*123 + 1M*456)/1e6, got ${pCustomCost}`);
  assert.notEqual(pCustomCost, defaultCost, "custom catalog must differ from default price table");

  // Positive `TranscriptCache` reuse via `timeline` (NOT tailRead) across initial, append, truncate, and .zst compression
  const tlArgs = { key: fx.sessionKey, from: "0", to: "100", viewer: fx.viewer };
  const [mInitTl, pInitTl] = await Promise.all([
    mb.ask({ ...baseAsk, id: 400, op: "timeline", args: tlArgs }),
    pion.ask({ ...baseAsk, id: 400, op: "timeline", args: tlArgs }),
  ]);
  const pInitEntries = (JSON.parse(pInitTl.body!) as { entries: Array<{ text?: string }> }).entries;
  assert.deepEqual(JSON.parse(pInitTl.body!), JSON.parse(mInitTl.body!), "initial timeline parity");
  assert.ok(pInitEntries.some((e) => e.text === "hello person"), "initial timeline must contain 'hello person'");

  const at2 = "2026-11-25T00:01:00.000Z";
  const extraLine =
    JSON.stringify({
      type: "assistant",
      timestamp: at2,
      message: { id: "m2", content: [{ type: "text", text: "appended turn" }] },
    }) + "\n";
  appendFileSync(join(mbDir, fx.transcriptRel), extraLine);
  appendFileSync(join(pionDir, fx.transcriptRel), extraLine);
  const [mAppTl, pAppTl] = await Promise.all([
    mb.ask({ ...baseAsk, id: 401, op: "timeline", args: tlArgs }),
    pion.ask({ ...baseAsk, id: 401, op: "timeline", args: tlArgs }),
  ]);
  assert.deepEqual(JSON.parse(pAppTl.body!), JSON.parse(mAppTl.body!), "timeline parity after append");
  assert.ok(
    (JSON.parse(pAppTl.body!) as { entries: Array<{ text?: string }> }).entries.some((e) => e.text === "appended turn"),
    "timeline after append must include 'appended turn'",
  );

  // Truncate/rewrite shorter
  const shortLine =
    JSON.stringify({ type: "user", timestamp: at2, message: { role: "user", content: "rewritten shorter" } }) + "\n";
  writeFileSync(join(mbDir, fx.transcriptRel), shortLine);
  writeFileSync(join(pionDir, fx.transcriptRel), shortLine);
  const [mTruncTl, pTruncTl] = await Promise.all([
    mb.ask({ ...baseAsk, id: 402, op: "timeline", args: tlArgs }),
    pion.ask({ ...baseAsk, id: 402, op: "timeline", args: tlArgs }),
  ]);
  assert.deepEqual(JSON.parse(pTruncTl.body!), JSON.parse(mTruncTl.body!), "timeline parity after truncate");
  assert.ok(
    (JSON.parse(pTruncTl.body!) as { entries: Array<{ text?: string }> }).entries.some((e) => e.text === "rewritten shorter"),
    "timeline after truncate must include 'rewritten shorter'",
  );

  // Replace .jsonl with .jsonl.zst compressed transcript and verify via `timeline`
  const zstLine =
    JSON.stringify({ type: "user", timestamp: at2, message: { role: "user", content: "compressed zst turn" } }) + "\n";
  const zstBytes = zstdCompressSync(Buffer.from(zstLine, "utf8"));
  for (const dir of [mbDir, pionDir]) {
    unlinkSync(join(dir, fx.transcriptRel));
    writeFileSync(join(dir, fx.transcriptRel) + ".zst", zstBytes);
  }
  const [mZstTl, pZstTl] = await Promise.all([
    mb.ask({ ...baseAsk, id: 403, op: "timeline", args: tlArgs }),
    pion.ask({ ...baseAsk, id: 403, op: "timeline", args: tlArgs }),
  ]);
  assert.deepEqual(JSON.parse(pZstTl.body!), JSON.parse(mZstTl.body!), "timeline parity after zst rewrite");
  assert.ok(
    (JSON.parse(pZstTl.body!) as { entries: Array<{ text?: string }> }).entries.some((e) => e.text === "compressed zst turn"),
    "timeline after zst rewrite must include 'compressed zst turn'",
  );
});

test("positive prepareWorkspaceUpJobs and prepareUpJobs emission, reset on next read, and non-leak on error", async (t) => {
  const bins = resolveDualBinaries();
  if (!bins) return;

  const root = mkdtempSync(join(tmpdir(), "w7f-signals-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));

  const fx = buildStationFixture(root);
  const mbDir = join(root, "mb");
  const pionDir = join(root, "pion");
  cpSync(fx.dataDir, mbDir, { recursive: true, preserveTimestamps: true });
  cpSync(fx.dataDir, pionDir, { recursive: true, preserveTimestamps: true });

  for (const dir of [mbDir, pionDir]) {
    const db = new DatabaseSync(join(dir, "stillfail.db"));
    // 1) Set workspace_up_meta ready=0 -> openJobs MUST emit prepareWorkspaceUpJobs: true
    db.exec(`
      CREATE TABLE IF NOT EXISTS workspace_up_meta(
        id INTEGER PRIMARY KEY CHECK(id=1), version INTEGER NOT NULL, phase INTEGER NOT NULL,
        last_port, last_rowid INTEGER, running_end INTEGER, guard_end INTEGER, guard_last INTEGER,
        port_batches INTEGER NOT NULL, ready INTEGER NOT NULL
      ) WITHOUT ROWID;
      DELETE FROM workspace_up_meta;
      INSERT INTO workspace_up_meta VALUES (1, 1, 0, NULL, NULL, NULL, NULL, NULL, 0, 0);
    `);
    // 2) Add 51 jobs for fx.sessionKey with session_up_job_meta unready -> session(jobs="now") MUST emit prepareUpJobs: fx.sessionKey
    db.exec(`
      CREATE TABLE IF NOT EXISTS session_up_job_meta (id INTEGER PRIMARY KEY CHECK (id = 1), version INTEGER NOT NULL, fresh INTEGER NOT NULL DEFAULT 0);
      CREATE TABLE IF NOT EXISTS session_up_job_scopes (session TEXT PRIMARY KEY, ready INTEGER NOT NULL DEFAULT 0);
      DELETE FROM session_up_job_meta;
      INSERT INTO session_up_job_meta (id, version, fresh) VALUES (1, 1, 0);
      DELETE FROM session_up_job_scopes;
    `);
    const insJob = db.prepare(
      `INSERT INTO jobs (id, session_key, name, command, cwd, token, state, exit_code, started_at, ended_at, log, watch)
       VALUES (?, ?, ?, 'echo ok', ?, ?, 'exited', 0, ?, ?, ?, 0)`,
    );
    const logPath = join(dir, "jobs", "job-1.log");
    for (let i = 0; i < 51; i++) {
      insJob.run(`bulk-job-${i}`, fx.sessionKey, `j${i}`, dir, `btok-${i}`, 1795580000000 + i, 1795580000500 + i, logPath);
    }
    db.close();
  }

  const mb = new RawDataClient(bins.mb, mbDir);
  const pion = new RawDataClient(bins.pion, pionDir);
  t.after(async () => {
    await Promise.all([mb.close(), pion.close()]);
  });
  await Promise.all([mb.ready(), pion.ready()]);

  const base = { lang: "en", now: 1795580000000, names: [], processes: [], clientKeys: [] };

  // A. openJobs -> prepareWorkspaceUpJobs === true on BOTH engines
  const [mOpen, pOpen] = await Promise.all([
    mb.ask({ ...base, id: 1, op: "openJobs", args: { viewer: fx.viewer } }),
    pion.ask({ ...base, id: 1, op: "openJobs", args: { viewer: fx.viewer } }),
  ]);
  assert.equal(mOpen.head.prepareWorkspaceUpJobs, true, "MB openJobs must emit prepareWorkspaceUpJobs=true");
  assert.equal(pOpen.head.prepareWorkspaceUpJobs, true, "Pion openJobs must emit prepareWorkspaceUpJobs=true");

  // Follow-up ok & error reads MUST NOT retain prepareWorkspaceUpJobs
  const [mAfterOpenOk, pAfterOpenOk] = await Promise.all([
    mb.ask({ ...base, id: 2, op: "threadList", args: {} }),
    pion.ask({ ...base, id: 2, op: "threadList", args: {} }),
  ]);
  assert.equal(mAfterOpenOk.head.prepareWorkspaceUpJobs, undefined);
  assert.equal(pAfterOpenOk.head.prepareWorkspaceUpJobs, undefined);

  const [mAfterOpenErr, pAfterOpenErr] = await Promise.all([
    mb.ask({ ...base, id: 3, op: "session", args: { key: "missing-s", viewer: fx.viewer } }),
    pion.ask({ ...base, id: 3, op: "session", args: { key: "missing-s", viewer: fx.viewer } }),
  ]);
  assert.equal(mAfterOpenErr.head.status, 404);
  assert.equal(pAfterOpenErr.head.status, 404);
  assert.equal(pAfterOpenErr.head.prepareWorkspaceUpJobs, undefined);

  // B. session(jobs="now") with 51 jobs -> prepareUpJobs === fx.sessionKey on BOTH engines
  const [mSess, pSess] = await Promise.all([
    mb.ask({ ...base, id: 4, op: "session", args: { key: fx.sessionKey, jobs: "now", viewer: fx.viewer } }),
    pion.ask({ ...base, id: 4, op: "session", args: { key: fx.sessionKey, jobs: "now", viewer: fx.viewer } }),
  ]);
  assert.equal(mSess.head.status, undefined, `MB session failed: ${mSess.headRaw}`);
  assert.equal(pSess.head.status, undefined, `Pion session failed: ${pSess.headRaw}`);
  assert.equal(mSess.head.prepareUpJobs, fx.sessionKey, "MB session must emit prepareUpJobs");
  assert.equal(pSess.head.prepareUpJobs, fx.sessionKey, "Pion session must emit prepareUpJobs");

  // Follow-up ok & error reads MUST NOT retain prepareUpJobs
  const [mAfterSessOk, pAfterSessOk] = await Promise.all([
    mb.ask({ ...base, id: 5, op: "threadList", args: {} }),
    pion.ask({ ...base, id: 5, op: "threadList", args: {} }),
  ]);
  assert.equal(mAfterSessOk.head.prepareUpJobs, undefined);
  assert.equal(pAfterSessOk.head.prepareUpJobs, undefined);

  const [mAfterSessErr, pAfterSessErr] = await Promise.all([
    mb.ask({ ...base, id: 6, op: "session", args: { key: "missing-s2", viewer: fx.viewer } }),
    pion.ask({ ...base, id: 6, op: "session", args: { key: "missing-s2", viewer: fx.viewer } }),
  ]);
  assert.equal(mAfterSessErr.head.status, 404);
  assert.equal(pAfterSessErr.head.status, 404);
  assert.equal(pAfterSessErr.head.prepareUpJobs, undefined);
});

test("wire checkpoint(hard) busy=1 contention, post-unlock PASSIVE completion, and external commit visibility", async (t) => {
  const bins = resolveDualBinaries();
  if (!bins) return;

  const root = mkdtempSync(join(tmpdir(), "w7f-contention-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));

  const fx = buildStationFixture(root);
  const pionDir = join(root, "pion");
  cpSync(fx.dataDir, pionDir, { recursive: true, preserveTimestamps: true });
  const dbPath = join(pionDir, "stillfail.db");

  const pion = new RawDataClient(bins.pion, pionDir);
  t.after(() => pion.close());
  await pion.ready();

  // Fill WAL pages from an external writer
  const writer = new DatabaseSync(dbPath);
  t.after(() => writer.close());
  writer.exec("CREATE TABLE IF NOT EXISTS filler (v TEXT)");
  const ins = writer.prepare("INSERT INTO filler (v) VALUES (?)");
  for (let i = 0; i < 400; i++) ins.run("w".repeat(4000));

  // Hold a read snapshot on a third connection so hard checkpoint cannot truncate -> busy === 1
  const holder = new DatabaseSync(dbPath, { readOnly: true });
  holder.exec("BEGIN");
  holder.prepare("SELECT COUNT(*) FROM filler").get();

  // Write more rows while holder holds snapshot, then run hard checkpoint
  for (let i = 0; i < 20; i++) ins.run("z".repeat(4000));

  const hardWhileHeld = await pion.ask({ id: 1, op: "checkpoint", args: { hard: true } });
  assert.equal(hardWhileHeld.head.status, undefined);
  const hardRow = JSON.parse(hardWhileHeld.body!) as { busy: number; log: number; checkpointed: number };
  assert.equal(hardRow.busy, 1, `expected hard checkpoint busy=1 while snapshot held, got ${hardWhileHeld.body}`);
  assert.ok(hardRow.checkpointed < hardRow.log, `expected partial checkpoint while held: ${hardWhileHeld.body}`);

  // Release holder and run passive checkpoint -> completes all frames
  // (PRAGMA busy_timeout === 0 restoration on ok/err paths & same-snapshot isolation are verified in native reader_data::run_selftest)
  holder.exec("COMMIT");
  holder.close();

  const passiveAfter = await pion.ask({ id: 2, op: "checkpoint", args: {} });
  assert.equal(passiveAfter.head.status, undefined);
  const passiveRow = JSON.parse(passiveAfter.body!) as { busy: number; log: number; checkpointed: number };
  assert.equal(passiveRow.busy, 0);
  assert.equal(passiveRow.checkpointed, passiveRow.log);

  // Verify subsequent read snapshot sees an external writer's committed row
  const beforeCount = (JSON.parse((await pion.ask({ id: 3, op: "threadList", args: {} })).body!) as unknown[]).length;
  writer
    .prepare(
      `INSERT INTO threads (surface, channel, thread_ts, title, created_by, created_at)
       VALUES ('chat', 'CHAT', '1795580099.000001', 'Concurrent', 'alice@example.com', 1795580099000)`,
    )
    .run();
  const afterCount = (JSON.parse((await pion.ask({ id: 4, op: "threadList", args: {} })).body!) as unknown[]).length;
  assert.equal(afterCount, beforeCount + 1, "subsequent read snapshot must see committed concurrent write");
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
  assert.equal(realpathSync(live1[0]!.binary), bins.pion, "cold-start data reader must execute Pion binary");

  // 2. Hot-reload config from pion -> mb -> new spawn uses bins.mb
  cfg = { readers: { data: "mb" } };
  readers.retireMismatchedIdle();
  const r2 = JSON.parse(await readers.read("threadList", {}, "en"));
  assert.deepEqual(r2, r1);
  const live2 = MbProcess.live().filter((p) => p.args.includes(fx.dataDir) && realpathSync(p.binary) === bins.mb);
  assert.ok(live2.length >= 1, "hot-reloaded data reader must execute MB binary");
  const prevMbPids = new Set(live2.map((p) => p.pid));
  readers.close();

  // 3. Explicit mbReader override always wins over config=pion (assert fresh MB PID, not leftover from step 2)
  cfg = { readers: { data: "pion" } };
  const explicit = new Readers(fx.dataDir, 1, undefined, 1, { readers: () => cfg });
  explicit.mbReader = bins.mb;
  t.after(() => explicit.close());
  const r3 = JSON.parse(await explicit.read("threadList", {}, "en"));
  assert.deepEqual(r3, r1);
  const live3 = MbProcess.live().filter(
    (p) => p.args.includes(fx.dataDir) && realpathSync(p.binary) === bins.mb && !prevMbPids.has(p.pid),
  );
  assert.ok(live3.length >= 1, "explicit mbReader override must spawn a fresh MB binary");

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

  // 5. OwnReader (standalone tailRead) hot-switches on the SAME instance from BIN_PION to BIN_MB
  //    (verified via thin exec-logging wrappers around the real binaries)
  const spawnLog = join(root, "own-reader-spawns.log");
  const makeWrapper = (name: string, targetBin: string): string => {
    const p = join(root, name);
    const q = (s: string) => `'${s.replace(/'/g, "'\\''")}'`;
    writeFileSync(
      p,
      `#!/bin/sh\nif [ "$1" != "--version" ]; then\n  printf '%s\\t%s\\n' ${q(targetBin)} "$*" >> ${q(spawnLog)}\nfi\nexec ${q(targetBin)} "$@"\n`,
      "utf8",
    );
    chmodSync(p, 0o755);
    return p;
  };
  const wrapPion = makeWrapper("wrap-pion.sh", bins.pion);
  const wrapMb = makeWrapper("wrap-mb.sh", bins.mb);
  const prevPionEnv = process.env.STILLFAIL_PION_READER;
  const prevMbEnv = process.env.STILLFAIL_MB_READER;
  process.env.STILLFAIL_PION_READER = wrapPion;
  process.env.STILLFAIL_MB_READER = wrapMb;
  resetReaderSelectionStateForTest();
  try {
    let ownCfg: { readers: { data: "pion" | "mb" } } = { readers: { data: "pion" } };
    const own = new OwnReader(() => ownCfg);
    t.after(() => own.close());
    const tPion = await own.tailRead("claude", { path: fx.transcriptPath });
    assert.ok(Array.isArray(tPion.entries) && tPion.entries.length >= 2);

    // OwnReader terminates its worker once idle; mutating config hot-switches the next tailRead to MB.
    ownCfg = { readers: { data: "mb" } };
    const tMb = await own.tailRead("claude", { path: fx.transcriptPath });
    assert.deepEqual(tMb, tPion);
    await own.close();

    const lines = readFileSync(spawnLog, "utf8").trim().split("\n").filter(Boolean);
    assert.equal(lines.length, 2, `expected exactly 2 OwnReader spawns, got: ${JSON.stringify(lines)}`);
    assert.ok(lines[0]!.startsWith(`${bins.pion}\t`), `1st OwnReader spawn must exec BIN_PION, got: ${lines[0]}`);
    assert.ok(lines[1]!.startsWith(`${bins.mb}\t`), `2nd OwnReader spawn must exec BIN_MB, got: ${lines[1]}`);
  } finally {
    if (prevPionEnv === undefined) delete process.env.STILLFAIL_PION_READER;
    else process.env.STILLFAIL_PION_READER = prevPionEnv;
    if (prevMbEnv === undefined) delete process.env.STILLFAIL_MB_READER;
    else process.env.STILLFAIL_MB_READER = prevMbEnv;
    resetReaderSelectionStateForTest();
  }
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

  // Real MB --sessions process started with exact production flags (`station/src/agents/mb-program.ts:29`)
  // (sessions left to its default: neither its own variable nor this run's STILLFAIL_READER_ENGINE moves it)
  const sessionsSel = await resolveReaderSelectionAsync("sessions", {
    config: { readers: { data: "pion" } },
    env: { ...process.env, STILLFAIL_READER_SESSIONS: undefined, STILLFAIL_READER_ENGINE: undefined },
  });
  assert.equal(sessionsSel.engine, "mb", "sessions mode must remain on MB in Wave 7");
  assert.equal(realpathSync(sessionsSel.primaryBinary), bins.mb, "sessions selection must resolve to BIN_MB");

  const sessionsProc = spawn(sessionsSel.primaryBinary, ["--sessions", "1", "--data", fx.dataDir, "--sep", sep], {
    stdio: ["pipe", "pipe", "pipe"],
  });
  t.after(async () => {
    sessionsProc.stdin.end();
    await new Promise<void>((resolve) => {
      if (sessionsProc.exitCode !== null) return resolve();
      sessionsProc.once("exit", () => resolve());
    });
  });

  // Exact handshake assertion: `--sessions 1` emits `{"ready":true}` (distinct from `--data`'s `{"ready":{"loadedMs":...}}`)
  const sessionsReady = await new Promise<string>((resolve, reject) => {
    let buf = "";
    sessionsProc.stdout.on("data", (c: Buffer) => {
      buf += c.toString("utf8");
      const nl = buf.indexOf("\n");
      if (nl >= 0) resolve(buf.slice(0, nl));
    });
    sessionsProc.once("exit", (code) => reject(new Error(`--sessions exited early: ${code}`)));
  });
  assert.deepEqual(JSON.parse(sessionsReady), { ready: true }, `unexpected --sessions handshake: ${sessionsReady}`);

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
