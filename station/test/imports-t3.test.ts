// Tests for T3 Code session importing: v2 and legacy v1 schemas, native Antigravity/Claude handoff,
// fallback runtimes, deduplication, workspace isolation, deletion re-import, and admin HTTP routes.
import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { test } from "node:test";
import { agyConversations, agyHome, geminiDir } from "../src/agents/agy.ts";
import { Admin } from "../src/api/admin.ts";
import type { Request } from "../src/api/request.ts";
import { listImportCandidates, listImportSources, runImport } from "../src/imports/service.ts";
import { mapT3Provider } from "../src/imports/t3.ts";
import { Jobs } from "../src/jobs/jobs.ts";
import { Readers } from "../src/read/pool.ts";
import { sharedTranscripts } from "../src/read/transcript.ts";
import { hubConfig } from "../src/sessions/config.ts";
import { Hub } from "../src/sessions/hub.ts";
import { InternalChat } from "../src/sessions/internal.ts";
import { deleteSession } from "../src/sessions/lifecycle.ts";
import { Store } from "../src/store/store.ts";
import { FakeDriver } from "./hub-fakes.ts";

const viewer = { sub: "u1", email: "user@example.com", name: "User", role: "member", workspace: "ws-home", device: "dev-1" };

function createRig() {
  const root = mkdtempSync(join(tmpdir(), "sf-t3-import-"));
  const data = join(root, "station");
  const t3Dir = join(root, "t3-userdata");
  const projA = join(root, "proj-a");
  const projB = join(root, "proj-b");
  const claudeRoot = join(root, "claude-projects");
  const codexRoot = join(root, "codex-sessions");
  mkdirSync(data, { recursive: true });
  mkdirSync(t3Dir, { recursive: true });
  mkdirSync(projA, { recursive: true });
  mkdirSync(projB, { recursive: true });
  mkdirSync(claudeRoot, { recursive: true });
  mkdirSync(codexRoot, { recursive: true });

  const raw = {
    profiles: [
      { id: "agy-main", runtime: "agy", home: "homes/agy-main", models: ["gemini-4-neon", "gemini-4-hydrogen"] },
      { id: "cc-main", runtime: "claude", home: "homes/cc-main", models: ["claude-opus-5-5"] },
    ],
  };
  const config = hubConfig(raw, data);
  const store = Store.open(join(data, "stillfail.db"), join(data, "archive"));
  const agy = new FakeDriver("agy");
  const claude = new FakeDriver("claude");
  const hub = new Hub({
    config: () => config,
    store,
    chats: () => undefined,
    drivers: [agy, claude],
    mcpUrl: "http://127.0.0.1:1/mcp",
    internal: new InternalChat(),
    runners: () => [],
  });
  const jobs = new Jobs({ store, data, notify: () => {}, link: () => null });
  hub.setJobs(jobs);
  const readers = new Readers(data, 1);
  readers.processes = () => hub.readProcesses();
  const admin = new Admin(readers, { store, agents: { hub, jobs } as any });

  const ask = async (method: string, path: string, body?: unknown, query: [string, string][] = [], who = viewer) => {
    const rawBody = Buffer.from(body === undefined ? "" : JSON.stringify(body));
    const r: Request = { method, path, query, headers: {}, body: rawBody, viewer: who, lang: "en" };
    const a = await admin.handle(r);
    return [a.status, JSON.parse(String(a.body))] as const;
  };

  const close = async () => {
    await hub.shutdown();
    await jobs.shutdown();
    readers.close();
    store.close();
    rmSync(root, { recursive: true, force: true });
  };

  return { root, data, t3Dir, projA, projB, claudeRoot, codexRoot, config, store, hub, admin, ask, close };
}

function seedT3V2Db(t3Dir: string, projA: string, projB: string, claudeRoot: string) {
  const dbPath = join(t3Dir, "statev2.sqlite");
  const db = new DatabaseSync(dbPath);
  db.exec(`
    CREATE TABLE projection_projects (
      project_id TEXT PRIMARY KEY,
      title TEXT NOT NULL,
      workspace_root TEXT NOT NULL
    );
    CREATE TABLE orchestration_v2_projection_threads (
      thread_id TEXT PRIMARY KEY,
      project_id TEXT NOT NULL,
      title TEXT NOT NULL,
      default_provider TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      archived_at TEXT,
      deleted_at TEXT,
      payload_json TEXT NOT NULL
    );
    CREATE TABLE orchestration_v2_projection_provider_sessions (
      provider_session_id TEXT PRIMARY KEY,
      thread_id TEXT NOT NULL,
      provider TEXT NOT NULL,
      status TEXT NOT NULL,
      model TEXT,
      updated_at TEXT NOT NULL,
      payload_json TEXT NOT NULL,
      driver TEXT
    );
    CREATE TABLE orchestration_v2_projection_provider_threads (
      provider_thread_id TEXT PRIMARY KEY,
      thread_id TEXT NOT NULL,
      provider TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      payload_json TEXT NOT NULL,
      driver TEXT
    );
    CREATE TABLE orchestration_v2_projection_messages (
      message_id TEXT PRIMARY KEY,
      thread_id TEXT NOT NULL,
      role TEXT NOT NULL,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      payload_json TEXT NOT NULL,
      search_text TEXT
    );
  `);

  db.prepare("INSERT INTO projection_projects VALUES (?, ?, ?)").run("p-a", "Alpha", projA);
  db.prepare("INSERT INTO projection_projects VALUES (?, ?, ?)").run("p-b", "Beta", projB);
  db.prepare("INSERT INTO projection_projects VALUES (?, ?, ?)").run("p-none", "No project", join(t3Dir, "missing-dir"));

  // 1. Active Antigravity thread with native .db, -wal, brain, annotations
  const agyNativeId = "11111111-2222-3333-4444-555555555555";
  db.prepare("INSERT INTO orchestration_v2_projection_threads VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)").run(
    "t3-agy-1",
    "p-a",
    "Momentum decoupling",
    "antigravity",
    "2026-11-20T08:00:00.000Z",
    "2026-11-24T07:26:00.000Z",
    null,
    null,
    JSON.stringify({
      modelSelection: { instanceId: "antigravity", model: "gemini-4-neon", options: [{ id: "thought_level", value: "xhigh" }] },
    }),
  );
  db.prepare("INSERT INTO orchestration_v2_projection_provider_sessions VALUES (?, ?, ?, ?, ?, ?, ?, ?)").run(
    "ps-1",
    "t3-agy-1",
    "antigravity",
    "ready",
    "gemini-4-neon",
    "2026-11-24T07:10:00.000Z",
    JSON.stringify({ cwd: projA, model: "gemini-4-neon" }),
    "antigravity",
  );
  db.prepare("INSERT INTO orchestration_v2_projection_provider_threads VALUES (?, ?, ?, ?, ?, ?)").run(
    "pt-1",
    "t3-agy-1",
    "antigravity",
    "2026-11-24T07:26:00.000Z",
    JSON.stringify({ nativeThreadRef: { driver: "antigravity", nativeId: agyNativeId } }),
    "antigravity",
  );
  db.prepare("INSERT INTO orchestration_v2_projection_messages VALUES (?, ?, ?, ?, ?, ?, ?)").run(
    "m-1",
    "t3-agy-1",
    "user",
    "2026-11-20T08:00:10.000Z",
    "2026-11-20T08:00:10.000Z",
    JSON.stringify({ role: "user", text: "Fix momentum decoupling", createdAt: "2026-11-20T08:00:10.000Z" }),
    "Fix momentum decoupling",
  );
  db.prepare("INSERT INTO orchestration_v2_projection_messages VALUES (?, ?, ?, ?, ?, ?, ?)").run(
    "m-2",
    "t3-agy-1",
    "assistant",
    "2026-11-20T08:01:00.000Z",
    "2026-11-20T08:01:00.000Z",
    JSON.stringify({ role: "assistant", text: "Updated the optimizer and verified tests.", createdAt: "2026-11-20T08:01:00.000Z" }),
    "Updated the optimizer and verified tests.",
  );

  // Create T3 Antigravity native files
  const acpDir = join(t3Dir, "providers", "antigravity", "hash123", "antigravity-acp");
  mkdirSync(join(acpDir, "conversations"), { recursive: true });
  mkdirSync(join(acpDir, "brain", agyNativeId), { recursive: true });
  mkdirSync(join(acpDir, "annotations"), { recursive: true });
  writeFileSync(join(acpDir, "conversations", `${agyNativeId}.db`), "FAKE-SQLITE-DB");
  writeFileSync(join(acpDir, "conversations", `${agyNativeId}.db-wal`), "FAKE-WAL");
  writeFileSync(join(acpDir, "brain", agyNativeId, "plan.md"), "# Plan");
  writeFileSync(join(acpDir, "annotations", `${agyNativeId}.pbtxt`), "annotation: 1");

  // 2. Active Claude thread with machine transcript
  const claudeNativeId = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";
  const claudeProj = join(claudeRoot, "-proj-b");
  mkdirSync(claudeProj, { recursive: true });
  writeFileSync(join(claudeProj, `${claudeNativeId}.jsonl`), `${JSON.stringify({ type: "user", message: { content: "hi" } })}\n`);
  db.prepare("INSERT INTO orchestration_v2_projection_threads VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)").run(
    "t3-claude-1",
    "p-b",
    "Claude refactor",
    "claude",
    "2026-11-21T09:00:00.000Z",
    "2026-11-23T09:00:00.000Z",
    null,
    null,
    JSON.stringify({ modelSelection: { model: "claude-opus-5-5" } }),
  );
  db.prepare("INSERT INTO orchestration_v2_projection_provider_sessions VALUES (?, ?, ?, ?, ?, ?, ?, ?)").run(
    "ps-2",
    "t3-claude-1",
    "claude",
    "ready",
    "claude-opus-5-5",
    "2026-11-23T09:00:00.000Z",
    JSON.stringify({ cwd: projB, model: "claude-opus-5-5" }),
    "claude",
  );
  db.prepare("INSERT INTO orchestration_v2_projection_provider_threads VALUES (?, ?, ?, ?, ?, ?)").run(
    "pt-2",
    "t3-claude-1",
    "claude",
    "2026-11-23T09:00:00.000Z",
    JSON.stringify({ nativeThreadRef: { driver: "claude", nativeId: claudeNativeId } }),
    "claude",
  );
  db.prepare("INSERT INTO orchestration_v2_projection_messages VALUES (?, ?, ?, ?, ?, ?, ?)").run(
    "m-3",
    "t3-claude-1",
    "user",
    "2026-11-21T09:00:05.000Z",
    "2026-11-21T09:00:05.000Z",
    JSON.stringify({ role: "user", text: "Refactor module B" }),
    "Refactor module B",
  );

  // 3. Active unsupported provider (opencode) with deleted cwd -> history-only fallback
  db.prepare("INSERT INTO orchestration_v2_projection_threads VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)").run(
    "t3-opencode-1",
    "p-none",
    "OpenCode review",
    "opencode",
    "2026-11-22T10:00:00.000Z",
    "2026-11-22T10:05:00.000Z",
    null,
    null,
    JSON.stringify({}),
  );
  db.prepare("INSERT INTO orchestration_v2_projection_messages VALUES (?, ?, ?, ?, ?, ?, ?)").run(
    "m-4",
    "t3-opencode-1",
    "user",
    "2026-11-22T10:00:01.000Z",
    "2026-11-22T10:00:01.000Z",
    JSON.stringify({ role: "user", text: "Review PR" }),
    "Review PR",
  );

  // 4. Archived thread (excluded from default active list unless includeArchived=true)
  db.prepare("INSERT INTO orchestration_v2_projection_threads VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)").run(
    "t3-archived-1",
    "p-a",
    "Old experiment",
    "antigravity",
    "2026-11-15T10:00:00.000Z",
    "2026-11-16T10:00:00.000Z",
    "2026-11-17T10:00:00.000Z",
    null,
    JSON.stringify({}),
  );

  // 5. Deleted thread and internal subagent/delegated threads (always excluded)
  db.prepare("INSERT INTO orchestration_v2_projection_threads VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)").run(
    "t3-deleted-1",
    "p-a",
    "Deleted chat",
    "antigravity",
    "2026-11-15T10:00:00.000Z",
    "2026-11-16T10:00:00.000Z",
    null,
    "2026-11-17T10:00:00.000Z",
    JSON.stringify({}),
  );
  db.prepare("INSERT INTO orchestration_v2_projection_threads VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)").run(
    "thread:subagent:deadbeef",
    "p-a",
    "Subagent worker",
    "antigravity",
    "2026-11-23T10:00:00.000Z",
    "2026-11-23T10:05:00.000Z",
    null,
    null,
    JSON.stringify({}),
  );
  db.prepare("INSERT INTO orchestration_v2_projection_threads VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)").run(
    "thread:delegated-task:abc",
    "p-a",
    "Delegated task",
    "antigravity",
    "2026-11-23T10:00:00.000Z",
    "2026-11-23T10:05:00.000Z",
    null,
    null,
    JSON.stringify({}),
  );
  db.close();
  return { agyNativeId, claudeNativeId };
}

test("mapT3Provider maps known providers and returns null for unknown ones", () => {
  assert.equal(mapT3Provider("antigravity"), "agy");
  assert.equal(mapT3Provider("claudeAgent"), "claude");
  assert.equal(mapT3Provider("codex"), "codex");
  assert.equal(mapT3Provider("grok"), "grok");
  assert.equal(mapT3Provider("opencode"), null);
  assert.equal(mapT3Provider(null), null);
});

test("T3 v2 probe, list, one-click import, native agy/claude handoff, idempotency, and re-import after delete", async () => {
  const r = createRig();
  try {
    const { agyNativeId, claudeNativeId } = seedT3V2Db(r.t3Dir, r.projA, r.projB, r.claudeRoot);
    const opts = { t3DataDir: r.t3Dir, machineRoots: { claude: r.claudeRoot, codex: r.codexRoot } };

    // Probe detects 3 active and 1 archived main thread (excluding deleted and subagents)
    const sources = await listImportSources(r.hub, null, opts);
    assert.equal(sources.length, 1);
    assert.equal(sources[0]!.id, "t3");
    assert.equal(sources[0]!.available, true);
    assert.equal(sources[0]!.activeCount, 3);
    assert.equal(sources[0]!.archivedCount, 1);
    assert.equal(sources[0]!.importedCount, 0);

    // List active only vs includeArchived
    const active = await listImportCandidates(r.hub, "t3", null, { includeArchived: false }, opts);
    assert.deepEqual(active.map((c) => c.id), ["t3-agy-1", "t3-claude-1", "t3-opencode-1"]);
    assert.equal(active[0]!.nativeResumable, true);
    assert.equal(active[0]!.runtime, "agy");
    assert.equal(active[0]!.effort, "xhigh");
    assert.equal(active[1]!.nativeResumable, true);
    assert.equal(active[2]!.nativeResumable, false);

    const withArchived = await listImportCandidates(r.hub, "t3", null, { includeArchived: true }, opts);
    assert.equal(withArchived.length, 4);
    assert.equal(withArchived[3]!.archived, true);

    // One-click import of all active threads
    const res = await runImport(r.hub, "t3", {}, viewer.email, "en", null, opts);
    assert.equal(res.imported, 3);
    assert.equal(res.skipped, 0);
    assert.equal(res.failed, 0);

    const agyItem = res.items.find((i) => i.id === "t3-agy-1")!;
    assert.equal(agyItem.status, "imported");
    assert.equal(agyItem.resumed, true);
    const agySession = r.store.getSession(agyItem.session!)!;
    assert.equal(agySession.runtime, "agy");
    assert.equal(agySession.model, "gemini-4-neon");
    assert.equal(agySession.effort, "xhigh");
    assert.equal(agySession.cwd, r.projA);
    assert.equal(agySession.runtimeSessionId, agyNativeId);

    // Verify native Antigravity files and KeptTranscript JSONL were materialized into profile home
    const agyProfileHome = join(r.data, "homes/agy-main");
    assert.equal(readFileSync(join(agyConversations(agyProfileHome), `${agyNativeId}.db`), "utf8"), "FAKE-SQLITE-DB");
    assert.equal(readFileSync(join(agyConversations(agyProfileHome), `${agyNativeId}.db-wal`), "utf8"), "FAKE-WAL");
    assert.equal(readFileSync(join(geminiDir(agyProfileHome), "antigravity-cli", "brain", agyNativeId, "plan.md"), "utf8"), "# Plan");
    assert.equal(readFileSync(join(geminiDir(agyProfileHome), "antigravity-cli", "annotations", `${agyNativeId}.pbtxt`), "utf8"), "annotation: 1");
    const jsonlPath = join(agyHome(agyProfileHome), "sessions", `${agyNativeId}.jsonl`);
    assert.ok(existsSync(jsonlPath));
    const jsonlLines = readFileSync(jsonlPath, "utf8").trim().split("\n").map((l) => JSON.parse(l));
    assert.equal(jsonlLines[0].type, "session");
    assert.equal(jsonlLines[1].type, "user");
    assert.equal(jsonlLines[2].type, "assistant");
    assert.equal(jsonlLines[3].type, "end");

    // Verify chat thread entries hold station origin note + user/assistant history and are marked read
    const entries = r.store.entriesAfter(agyItem.thread!, 0);
    assert.equal(entries.length, 3);
    assert.match(entries[0]!.text ?? "", /Imported from T3 Code/);
    assert.equal(entries[1]!.authorKind, "person");
    assert.equal(entries[1]!.text, "Fix momentum decoupling");
    assert.equal(entries[2]!.authorKind, "agent");
    assert.equal(entries[2]!.text, "Updated the optimizer and verified tests.");
    assert.equal(r.store.readPosition(viewer.email, agyItem.thread!), r.store.lastEntry(agyItem.thread!));

    // Verify Claude native transcript was copied into shared transcripts
    const claudeItem = res.items.find((i) => i.id === "t3-claude-1")!;
    assert.equal(claudeItem.resumed, true);
    assert.ok(existsSync(join(sharedTranscripts(r.data, "claude"), "-proj-b", `${claudeNativeId}.jsonl`)));

    // Verify opencode fallback kept messages and fell back to available profile without failing on missing cwd
    const ocItem = res.items.find((i) => i.id === "t3-opencode-1")!;
    assert.equal(ocItem.status, "imported");
    assert.equal(ocItem.resumed, false);
    const ocSession = r.store.getSession(ocItem.session!)!;
    assert.equal(ocSession.cwd, null);
    assert.equal(ocSession.runtimeSessionId, null);
    assert.equal(r.store.entriesAfter(ocItem.thread!, 0).length, 2);

    // Re-running one-click import is idempotent and skips already-imported conversations
    const again = await runImport(r.hub, "t3", {}, viewer.email, "en", null, opts);
    assert.equal(again.imported, 0);
    assert.equal(again.skipped, 3);
    assert.equal(again.failed, 0);

    // Source summary now reports importedCount = 3, and candidates carry their session keys
    const sourcesAfter = await listImportSources(r.hub, null, opts);
    assert.equal(sourcesAfter[0]!.importedCount, 3);
    const listedAfter = await listImportCandidates(r.hub, "t3", null, { includeArchived: false }, opts);
    assert.equal(listedAfter[0]!.session, agyItem.session);

    // Deleting an imported session clears its import mapping so it can be re-imported cleanly
    await deleteSession(r.hub, ocItem.session!);
    const reimport = await runImport(r.hub, "t3", { ids: ["t3-opencode-1"] }, viewer.email, "en", null, opts);
    assert.equal(reimport.imported, 1);
    assert.notEqual(reimport.items[0]!.session, ocItem.session);
  } finally {
    await r.close();
  }
});

test("T3 legacy v1 schema fallback imports threads and messages", async () => {
  const r = createRig();
  try {
    const db = new DatabaseSync(join(r.t3Dir, "state.sqlite"));
    db.exec(`
      CREATE TABLE projection_projects (project_id TEXT PRIMARY KEY, title TEXT NOT NULL, workspace_root TEXT NOT NULL);
      CREATE TABLE projection_threads (
        thread_id TEXT PRIMARY KEY, project_id TEXT NOT NULL, title TEXT NOT NULL, worktree_path TEXT,
        model_selection_json TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL, archived_at TEXT, deleted_at TEXT
      );
      CREATE TABLE projection_thread_messages (
        message_id TEXT PRIMARY KEY, thread_id TEXT NOT NULL, role TEXT NOT NULL, text TEXT NOT NULL, created_at TEXT NOT NULL
      );
      CREATE TABLE projection_thread_sessions (
        thread_id TEXT PRIMARY KEY, provider_name TEXT, provider_session_id TEXT, provider_thread_id TEXT
      );
    `);
    db.prepare("INSERT INTO projection_projects VALUES (?, ?, ?)").run("p1", "Legacy", r.projA);
    db.prepare("INSERT INTO projection_threads VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)").run(
      "legacy-1", "p1", "Legacy thread", null, JSON.stringify({ model: "gemini-4-neon" }),
      "2026-10-01T00:00:00.000Z", "2026-10-02T00:00:00.000Z", null, null,
    );
    db.prepare("INSERT INTO projection_thread_sessions VALUES (?, ?, ?, ?)").run("legacy-1", "antigravity", null, null);
    db.prepare("INSERT INTO projection_thread_messages VALUES (?, ?, ?, ?, ?)").run(
      "lm-1", "legacy-1", "user", "Hello legacy", "2026-10-01T00:00:01.000Z",
    );
    db.close();

    const opts = { t3DataDir: r.t3Dir };
    const sources = await listImportSources(r.hub, null, opts);
    assert.equal(sources[0]!.available, true);
    assert.equal(sources[0]!.activeCount, 1);
    const res = await runImport(r.hub, "t3", {}, viewer.email, "en", null, opts);
    assert.equal(res.imported, 1);
    assert.equal(r.store.entriesAfter(res.items[0]!.thread!, 0).length, 2);
  } finally {
    await r.close();
  }
});

test("admin HTTP routes serve /imports, /imports/t3/sessions, and POST /imports/t3/run", async () => {
  const r = createRig();
  const prevEnv = process.env.T3_DATA_DIR;
  process.env.T3_DATA_DIR = r.t3Dir;
  try {
    seedT3V2Db(r.t3Dir, r.projA, r.projB, r.claudeRoot);

    const [st1, body1] = await r.ask("GET", "/imports");
    assert.equal(st1, 200);
    assert.equal(body1.sources[0].id, "t3");
    assert.equal(body1.sources[0].activeCount, 3);

    const [st2, body2] = await r.ask("GET", "/imports/t3/sessions");
    assert.equal(st2, 200);
    assert.equal(body2.sessions.length, 3);

    const [st3, body3] = await r.ask("GET", "/imports/t3/sessions", undefined, [["includeArchived", "1"]]);
    assert.equal(st3, 200);
    assert.equal(body3.sessions.length, 4);

    const [st4] = await r.ask("GET", "/imports/unknown/sessions");
    assert.equal(st4, 404);

    // Read-only viewer cannot trigger imports
    const [stRo] = await r.ask("POST", "/imports/t3/run", {}, [], { ...viewer, role: "viewer" });
    assert.equal(stRo, 403);

    // Member can run one-click import
    const [st5, body5] = await r.ask("POST", "/imports/t3/run", {});
    assert.equal(st5, 200);
    assert.equal(body5.imported, 3);
    assert.equal(body5.skipped, 0);
  } finally {
    if (prevEnv === undefined) delete process.env.T3_DATA_DIR;
    else process.env.T3_DATA_DIR = prevEnv;
    await r.close();
  }
});
