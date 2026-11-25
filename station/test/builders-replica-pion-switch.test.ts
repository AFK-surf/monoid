// Dual-engine parity, cross-engine handover, fault-injection, and production entrypoint tests
// for Wave 6-B (`--builder replica-export`, `--builder replica-restore`, `--builder replica-carry`).
// Automatically skips when STILLFAIL_PION_READER is unset (e.g. `pipeline` without Pion binary);
// strictly enforces 0-skip and distinct MB vs Pion binaries when STILLFAIL_REQUIRE_DUAL_READER=1.

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import {
  chmodSync,
  cpSync,
  existsSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  readlinkSync,
  realpathSync,
  renameSync,
  rmSync,
  statSync,
  symlinkSync,
  utimesSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, sep } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { after, test } from "node:test";
import {
  MbProcess,
  mbReaderBinary,
  pionBinary,
  resetReaderSelectionStateForTest,
  setPionProbeRunnerForTest,
} from "../src/read/mb-reader.ts";
import { gatherSoon, placeSoon, previewSoon, sizesSoon } from "../src/replica/carry.ts";
import { tell } from "../src/replica/copies.ts";
import { takeBackSoon } from "../src/replica/restore.ts";
import { ProgramRunner } from "../src/replica/runner.ts";
import { Store } from "../src/store/store.ts";
import { nothingTold } from "./reference/replica-export.ts";
import { HOME, ORIGIN, OTHER, attach, chat, rowsOf, station } from "./replica-fakes.ts";

type Json = any;
const NOW = 1_700_000_000_000;
const PLACES = {
  home: HOME,
  workspaces: [
    { workspace: HOME, name: "laptop" },
    { workspace: OTHER, name: "laptop-other" },
  ],
};

const cleanupDirs: string[] = [];
const startedProcs = new Set<MbProcess>();

after(async () => {
  await Promise.all([...startedProcs].map((p) => p.terminate().catch(() => {})));
  for (const d of cleanupDirs) {
    try {
      rmSync(d, { recursive: true, force: true });
    } catch {
      // best effort
    }
  }
});

function tempDir(prefix: string): string {
  const d = mkdtempSync(join(tmpdir(), prefix));
  cleanupDirs.push(d);
  return d;
}

function resolveDualBinaries(t: { skip: (msg: string) => void }): { mb: string; pion: string } | null {
  const realMb = mbReaderBinary();
  const explicitPion = process.env.STILLFAIL_PION_READER?.trim();
  const requireDual = process.env.STILLFAIL_REQUIRE_DUAL_READER === "1";
  const realPion = pionBinary();

  if (realMb === null) {
    if (process.env.CI || requireDual) assert.fail("stillfail-reader binary is required in CI");
    t.skip("stillfail-reader not built here");
    return null;
  }
  if (explicitPion || requireDual) {
    assert.ok(realPion !== null, `STILLFAIL_PION_READER is required (${explicitPion ?? "unset"}) but resolved to null`);
  } else if (realPion === null) {
    t.skip("STILLFAIL_PION_READER / built stillfail-pion binary not present in this environment");
    return null;
  }
  assert.notEqual(realpathSync(realMb), realpathSync(realPion), "MB and Pion binaries must be distinct files");
  const ver = execFileSync(realPion, ["--version"], { encoding: "utf8" });
  const m = ver.match(/modes:([^\s]+)/);
  assert.ok(m !== null, `Pion --version must include modes: list: ${ver}`);
  const advertised = new Set(m[1]!.split(","));
  for (const mode of ["replica-export", "replica-restore", "replica-carry"]) {
    assert.ok(advertised.has(mode), `Pion --version must advertise exact mode ${mode}: ${ver}`);
  }
  return { mb: realMb, pion: realPion };
}

function makeRecordingWrapper(dir: string, name: string, realBin: string, logFile: string): string {
  const wrapper = join(dir, name);
  const sh = [
    "#!/bin/sh",
    `printf '%s %s\\n' "$$" "$*" >> ${JSON.stringify(logFile)}`,
    `exec ${JSON.stringify(realBin)} "$@"`,
    "",
  ].join("\n");
  writeFileSync(wrapper, sh, "utf8");
  chmodSync(wrapper, 0o755);
  return wrapper;
}

function readSpawns(logFile: string): string[] {
  if (!existsSync(logFile)) return [];
  return readFileSync(logFile, "utf8")
    .split("\n")
    .map((s) => s.trim())
    .filter(Boolean);
}

function countBuilderSpawns(logFile: string, mode: string): number {
  return readSpawns(logFile).filter((line) => line.includes(`--builder ${mode}`)).length;
}

async function withEnv<T>(overrides: Record<string, string | undefined>, fn: () => Promise<T>): Promise<T> {
  const saved = new Map<string, string | undefined>();
  for (const [k, v] of Object.entries(overrides)) {
    saved.set(k, process.env[k]);
    if (v === undefined) delete process.env[k];
    else process.env[k] = v;
  }
  resetReaderSelectionStateForTest();
  try {
    return await fn();
  } finally {
    for (const [k, v] of saved) {
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
    resetReaderSelectionStateForTest();
  }
}

class ExportClient {
  readonly #p: MbProcess;
  readonly #waiting = new Map<number, { resolve: (v: Json) => void; reject: (e: Error) => void }>();
  #next = 0;
  now = NOW;

  constructor(bin: string, db: string, replica: string, data: string, extraArgs: string[] = []) {
    const args = [
      "--builder",
      "replica-export",
      "--db",
      db,
      "--replica",
      replica,
      "--data-dir",
      data,
      "--origin",
      ORIGIN,
      "--sep",
      sep,
      ...extraArgs,
    ];
    this.#p = new MbProcess(bin, args);
    startedProcs.add(this.#p);
    this.#p.on("message", (m: Json) => {
      const w = this.#waiting.get(m.id);
      this.#waiting.delete(m.id);
      if (m.error !== undefined) w?.reject(new Error(m.error));
      else w?.resolve(m.answer);
    });
    this.#p.on("exit", () => {
      for (const w of this.#waiting.values()) w.reject(new Error("the program ended"));
      this.#waiting.clear();
    });
  }

  ask(m: Json): Promise<Json> {
    const id = ++this.#next;
    return new Promise((resolve, reject) => {
      this.#waiting.set(id, { resolve, reject });
      this.#p.postMessage({ ...m, id, now: this.now });
    });
  }

  async close(): Promise<void> {
    await this.ask({ type: "close" });
    await this.#p.terminate();
  }
}

function stageRestoreCopy(
  srcReplica: string,
  srcData: string,
  ws: string,
  gen: string,
  destData: string,
  sources: Record<string, string>,
  readyExtra: Record<string, unknown> = {},
): void {
  const restoreDir = join(destData, "restore");
  const copyGenDir = join(restoreDir, "copy", gen);
  const copyFilesDir = join(restoreDir, "copy", "files");
  mkdirSync(copyFilesDir, { recursive: true });
  cpSync(join(srcReplica, "own", ws, gen), copyGenDir, { recursive: true });
  for (const [hash, filePath] of Object.entries(sources)) {
    if (existsSync(filePath)) {
      cpSync(filePath, join(copyFilesDir, hash));
    }
  }
  const ready = {
    origin: ORIGIN,
    name: "laptop",
    from: "peer-1",
    gen,
    ...readyExtra,
  };
  writeFileSync(join(restoreDir, "ready.json"), JSON.stringify(ready));
  void srcData;
}

function dumpTableRows(dbPath: string, table: string): Json[] {
  const db = new DatabaseSync(dbPath, { readOnly: true });
  try {
    return db.prepare(`SELECT * FROM ${table}`).all() as Json[];
  } finally {
    db.close();
  }
}

function makeRichStation(): {
  made: ReturnType<typeof station>;
  attPath: string;
  trPath: string;
} {
  const made = station();
  cleanupDirs.push(made.data);
  const { store, data } = made;
  const att = attach(data, "chat:a", "hello.txt", "attachment-bytes-12345\n");
  const attPath = att.path;
  const t = store.db.prepare("SELECT id FROM threads ORDER BY id LIMIT 1").get() as { id: number };
  store.insertMessage({
    thread: t.id,
    ts: "r1.att",
    authorKind: "person",
    author: "p@x",
    text: "with attachment",
    attachments: [att],
  });
  store.setChatHidden("p@x", t.id, true);
  store.setRuntimeSessionId("chat:a", "rt-agy-1");
  store.db
    .prepare("INSERT INTO runtime_sessions (session_key, id, runtime, profile, at) VALUES (?, ?, ?, ?, ?)")
    .run("chat:a", "rt-agy-1", "agy", "p1", NOW);
  const trDir = join(data, "transcripts", "agy");
  mkdirSync(trDir, { recursive: true });
  const trPath = join(trDir, "rt-agy-1.jsonl");
  writeFileSync(trPath, '{"type":"turn","text":"hello transcript"}\n');
  chmodSync(trPath, 0o640);
  return { made, attPath, trPath };
}

test("bidirectional MB export -> Pion restore and Pion export -> MB restore produce 0-diff DB, files, modes, and markers", async (t) => {
  const bins = resolveDualBinaries(t);
  if (!bins) return;

  const { made, attPath } = makeRichStation();
  const repMb = join(made.data, "replica-mb");
  const repPion = join(made.data, "replica-pion");

  const expMb = new ExportClient(bins.mb, made.db, repMb, made.data);
  await expMb.ask({ type: "places", places: PLACES });
  const passMb = await expMb.ask({ type: "pass", told: nothingTold() });
  const headMb = passMb.heads[HOME];
  const hashesMb = [...Object.keys(headMb.files ?? {}), ...Object.keys(headMb.transcriptFiles ?? {})];
  const sourcesMb = await expMb.ask({ type: "sources", hashes: hashesMb });
  await expMb.close();

  const expPion = new ExportClient(bins.pion, made.db, repPion, made.data);
  await expPion.ask({ type: "places", places: PLACES });
  const passPion = await expPion.ask({ type: "pass", told: nothingTold() });
  const headPion = passPion.heads[HOME];
  const hashesPion = [...Object.keys(headPion.files ?? {}), ...Object.keys(headPion.transcriptFiles ?? {})];
  const sourcesPion = await expPion.ask({ type: "sources", hashes: hashesPion });
  await expPion.close();

  assert.deepEqual(Object.keys(headPion.files).sort(), Object.keys(headMb.files).sort());
  assert.deepEqual(
    Object.keys(headPion.transcriptFiles ?? {}).sort(),
    Object.keys(headMb.transcriptFiles ?? {}).sort(),
  );

  // 1) MB export -> Pion restore
  const destA = tempDir("w6b-mb-to-pion-");
  const dbA = join(destA, "stillfail.db");
  Store.open(dbA).close();
  stageRestoreCopy(repMb, made.data, HOME, headMb.gen, destA, sourcesMb);
  const resA = await takeBackSoon(destA, dbA, NOW + 100, bins.pion);
  assert.ok(resA !== null);

  // 2) Pion export -> MB restore
  const destB = tempDir("w6b-pion-to-mb-");
  const dbB = join(destB, "stillfail.db");
  Store.open(dbB).close();
  stageRestoreCopy(repPion, made.data, HOME, headPion.gen, destB, sourcesPion);
  const resB = await takeBackSoon(destB, dbB, NOW + 100, bins.mb);
  assert.ok(resB !== null);

  assert.ok(Object.keys(headPion.transcriptFiles ?? {}).length >= 1, "headPion.transcriptFiles must be non-empty");

  // Compare ALL RESTORE_ORDER tables (including hidden_chats, turns, reads, pins, closed_cards, opened_chats)
  // directly against source DB expected rows via replica-fakes.ts `rowsOf`, plus separate `replica_restored` check.
  const srcDbConn = new DatabaseSync(made.db, { readOnly: true });
  const dbAConn = new DatabaseSync(dbA, { readOnly: true });
  const dbBConn = new DatabaseSync(dbB, { readOnly: true });
  try {
    const expectedA = rowsOf(srcDbConn, null, made.data, destA);
    const expectedB = rowsOf(srcDbConn, null, made.data, destB);
    const actualA = rowsOf(dbAConn, null);
    const actualB = rowsOf(dbBConn, null);
    assert.ok(expectedA.hidden_chats!.size >= 1, "fixture must seed hidden_chats");
    assert.deepEqual(actualA, expectedA, "MB export -> Pion restore must match source DB rows 0-diff across all tables");
    assert.deepEqual(actualB, expectedB, "Pion export -> MB restore must match source DB rows 0-diff across all tables");
  } finally {
    srcDbConn.close();
    dbAConn.close();
    dbBConn.close();
  }
  const restRowsA = dumpTableRows(dbA, "replica_restored").map((r) => JSON.stringify(r).replaceAll(headMb.gen, "<GEN>"));
  const restRowsB = dumpTableRows(dbB, "replica_restored").map((r) => JSON.stringify(r).replaceAll(headPion.gen, "<GEN>"));
  assert.deepEqual(restRowsA, restRowsB, "table replica_restored must match 0-diff between MB->Pion and Pion->MB");

  // Regular attachment content must also be restored identically on both sides.
  const attRel = attPath.slice(made.data.length + 1);
  assert.equal(readFileSync(join(destA, attRel), "utf8"), "attachment-bytes-12345\n");
  assert.equal(readFileSync(join(destB, attRel), "utf8"), "attachment-bytes-12345\n");

  const trA = join(destA, "transcripts", "agy", "rt-agy-1.jsonl");
  const trB = join(destB, "transcripts", "agy", "rt-agy-1.jsonl");
  assert.equal(readFileSync(trA, "utf8"), readFileSync(trB, "utf8"));
  assert.equal(statSync(trA).mode & 0o777, statSync(trB).mode & 0o777);
  assert.deepEqual(
    JSON.parse(readFileSync(join(destA, "replica", "formerly.json"), "utf8")),
    JSON.parse(readFileSync(join(destB, "replica", "formerly.json"), "utf8")),
  );
  const restA = JSON.parse(readFileSync(join(destA, "replica", "restored.json"), "utf8"));
  const restB = JSON.parse(readFileSync(join(destB, "replica", "restored.json"), "utf8"));
  assert.equal(restA.error, null);
  assert.equal(restB.error, null);
  assert.equal(restA.pending, false);
  assert.equal(restB.pending, false);
  assert.deepEqual(restA.rows, restB.rows);
  assert.equal(restA.files, restB.files);
  assert.equal(existsSync(join(destA, "restore")), false);
  assert.equal(existsSync(join(destB, "restore")), false);
});

test("empty DB restore preserves original conv vs non-empty merge calls settle_conversation_in_tx", async (t) => {
  const bins = resolveDualBinaries(t);
  if (!bins) return;

  // Source station with two scope='thread' sessions sharing one Slack thread, with distinct conv values.
  const srcDir = tempDir("w6b-conv-src-");
  const srcDb = join(srcDir, "stillfail.db");
  const srcStore = Store.open(srcDb);
  const th = srcStore.openThread("slack", "C9", "1700.9999", "Slack Conv", "p@x");
  const ws1 = join(srcDir, "sessions", "slack", "s1", "workspace");
  const ws2 = join(srcDir, "sessions", "slack", "s2", "workspace");
  mkdirSync(ws1, { recursive: true });
  mkdirSync(ws2, { recursive: true });
  srcStore.insertSession({
    key: "slack:C9:1700.9999",
    connect: "slack",
    scope: "thread",
    runtime: "claude",
    profile: "cc",
    workspace: ws1,
    token: "t1",
    createdAt: 100,
    lastActiveAt: 100,
    ws: HOME,
  });
  srcStore.insertSession({
    key: "slack2:C9:1700.9999",
    connect: "slack2",
    scope: "thread",
    runtime: "claude",
    profile: "cc",
    workspace: ws2,
    token: "t2",
    createdAt: 200,
    lastActiveAt: 200,
    ws: HOME,
  });
  srcStore.db
    .prepare("INSERT INTO thread_sessions (thread, session, connect, joined_at) VALUES (?, ?, ?, ?)")
    .run(th.id, "slack:C9:1700.9999", "slack", 100);
  srcStore.db
    .prepare("INSERT INTO thread_sessions (thread, session, connect, joined_at) VALUES (?, ?, ?, ?)")
    .run(th.id, "slack2:C9:1700.9999", "slack2", 200);
  // Explicitly give them distinct conv values so we can tell whether settle ran!
  srcStore.db.prepare("UPDATE sessions SET conv = ? WHERE key = ?").run("keep-conv-1", "slack:C9:1700.9999");
  srcStore.db.prepare("UPDATE sessions SET conv = ? WHERE key = ?").run("keep-conv-2", "slack2:C9:1700.9999");
  srcStore.close();

  const srcRep = join(srcDir, "replica");
  const exp = new ExportClient(bins.pion, srcDb, srcRep, srcDir);
  await exp.ask({ type: "places", places: PLACES });
  const passed = await exp.ask({ type: "pass", told: nothingTold() });
  const head = passed.heads[HOME];
  await exp.close();

  // Case 1: Empty DB restore MUST preserve original `conv` (must NOT call settle_conversation_in_tx).
  const emptyDest = tempDir("w6b-conv-empty-");
  const emptyDb = join(emptyDest, "stillfail.db");
  Store.open(emptyDb).close();
  stageRestoreCopy(srcRep, srcDir, HOME, head.gen, emptyDest, {});
  await takeBackSoon(emptyDest, emptyDb, NOW + 200, bins.pion);
  const emptyRows = new Map(dumpTableRows(emptyDb, "sessions").map((r) => [r.key, r.conv]));
  assert.equal(emptyRows.get("slack:C9:1700.9999"), "keep-conv-1", "empty restore must preserve conv 1");
  assert.equal(emptyRows.get("slack2:C9:1700.9999"), "keep-conv-2", "empty restore must preserve conv 2");

  // Case 2: Non-empty DB with merge: false MUST fail with reason "notEmpty".
  const noMergeDest = tempDir("w6b-conv-nomerge-");
  const noMergeDb = join(noMergeDest, "stillfail.db");
  const nmStore = Store.open(noMergeDb);
  chat(nmStore, noMergeDest, "chat:existing", null, 1);
  nmStore.close();
  stageRestoreCopy(srcRep, srcDir, HOME, head.gen, noMergeDest, {}, { merge: false });
  await takeBackSoon(noMergeDest, noMergeDb, NOW + 200, bins.pion);
  const nmOutcome = JSON.parse(readFileSync(join(noMergeDest, "replica", "restored.json"), "utf8"));
  assert.equal(nmOutcome.reason, "notEmpty");

  // Case 3: Non-empty DB with merge: true MUST call settle_conversation_in_tx, unifying both sessions' conv.
  const mergeDest = tempDir("w6b-conv-merge-");
  const mergeDb = join(mergeDest, "stillfail.db");
  const mStore = Store.open(mergeDb);
  chat(mStore, mergeDest, "chat:existing", null, 1);
  mStore.close();
  stageRestoreCopy(srcRep, srcDir, HOME, head.gen, mergeDest, {}, { merge: true });
  await takeBackSoon(mergeDest, mergeDb, NOW + 200, bins.pion);
  const mergeRows = new Map(dumpTableRows(mergeDb, "sessions").map((r) => [r.key, r.conv]));
  assert.equal(
    mergeRows.get("slack:C9:1700.9999"),
    mergeRows.get("slack2:C9:1700.9999"),
    "non-empty merge restore must run settle_conversation_in_tx to unify conv",
  );
  assert.equal(mergeRows.get("slack:C9:1700.9999"), "keep-conv-1");
});

test("forced head write failure rolls back export.db cleanly and retries on next pass", async (t) => {
  const bins = resolveDualBinaries(t);
  if (!bins) return;

  const { made, attPath } = makeRichStation();
  const rep = join(made.data, "replica-fault");
  const exp = new ExportClient(bins.pion, made.db, rep, made.data);
  await exp.ask({ type: "places", places: PLACES });
  // Pass 1 establishes gen dir.
  const p1 = await exp.ask({ type: "pass", told: nothingTold() });
  const gen = p1.heads[HOME].gen as string;
  const genDir = join(rep, "own", HOME, gen);
  const headPath = join(genDir, "head.json");
  const savedHead = readFileSync(headPath, "utf8");
  const isRoot = typeof process.getuid === "function" && process.getuid() === 0;

  // Add a new entry and block writing head.json (chmod 0555 on genDir lets read_head_checked + log/ write succeed,
  // then fails at write_head after pass_in has mutated in-memory state).
  const told = nothingTold();
  made.store.subscribe((c) => void tell(told, c));
  const th = made.store.db.prepare("SELECT id FROM threads ORDER BY id LIMIT 1").get() as { id: number };
  made.store.insertMessage({ thread: th.id, ts: "r2.fault", authorKind: "person", author: "p@x", text: "after-head-fault" });
  if (!isRoot) {
    chmodSync(genDir, 0o555);
  } else {
    rmSync(headPath);
    mkdirSync(headPath);
  }

  try {
    await assert.rejects(() => exp.ask({ type: "pass", told }), /EACCES|Permission denied|cannot read|EISDIR|Is a directory/i);
  } finally {
    if (!isRoot) {
      chmodSync(genDir, 0o755);
    } else {
      rmSync(headPath, { recursive: true, force: true });
      writeFileSync(headPath, savedHead);
    }
  }
  const p2 = await exp.ask({ type: "pass", told });
  assert.ok(p2.wrote >= 1, "retry pass after head write failure must write the rolled-back entry");
  await exp.close();

  // Cold-start first pass head write failure -> fix path -> same-process retry must NOT lose source DB changes (both MB & Pion).
  for (const [label, bin] of [
    ["mb", bins.mb],
    ["pion", bins.pion],
  ] as const) {
    const { made: m2 } = makeRichStation();
    const rep2 = join(m2.data, `replica-cold-fault-${label}`);
    // Run pass 1, capture gen, then start a brand-new cold process where write_head fails on its FIRST pass.
    const seed = new ExportClient(bin, m2.db, rep2, m2.data);
    await seed.ask({ type: "places", places: PLACES });
    const sp1 = await seed.ask({ type: "pass", told: nothingTold() });
    const g2 = sp1.heads[HOME].gen as string;
    const g2Dir = join(rep2, "own", HOME, g2);
    const h2Path = join(g2Dir, "head.json");
    const h2Saved = readFileSync(h2Path, "utf8");
    const logDir2 = join(g2Dir, "log");
    await seed.close();

    // Modify an existing session's metadata field (which requires cold full-scan, not just incremental entries cursor!)
    // while cold exporter is stopped, then block write_head by making genDir read-only (head.json & log/ stay accessible
    // so pass_in executes the full scan and mutates `known` before failing at write_head).
    m2.store.db.prepare("UPDATE sessions SET model = ? WHERE key = ?").run(`r2-cold-model-${label}`, "chat:a");
    if (!isRoot) {
      chmodSync(g2Dir, 0o555);
    } else {
      rmSync(h2Path);
      mkdirSync(h2Path);
    }

    const cold = new ExportClient(bin, m2.db, rep2, m2.data);
    cold.now = NOW + 2000;
    await cold.ask({ type: "places", places: PLACES });
    try {
      await assert.rejects(() => cold.ask({ type: "pass", told: nothingTold() }), /EACCES|Permission denied|cannot read|EISDIR|Is a directory/i);
    } finally {
      if (!isRoot) {
        chmodSync(g2Dir, 0o755);
      } else {
        rmSync(h2Path, { recursive: true, force: true });
        writeFileSync(h2Path, h2Saved);
      }
    }
    const retry = await cold.ask({ type: "pass", told: nothingTold() });
    assert.ok(retry.wrote >= 1, `${label}: same-process retry after cold-start head failure must write >= 1`);
    const retryHead = retry.heads[HOME];
    const onDiskBatches = readdirSync(logDir2).sort();
    assert.deepEqual(onDiskBatches, [...(retryHead.batches as string[])].sort(), `${label}: orphan batches must be cleaned after retry`);
    const hashes2 = [...Object.keys(retryHead.files ?? {}), ...Object.keys(retryHead.transcriptFiles ?? {})];
    const sources2 = await cold.ask({ type: "sources", hashes: hashes2 });
    await cold.close();

    const dest2 = tempDir(`w6b-cold-fault-dest-${label}-`);
    const destDb2 = join(dest2, "stillfail.db");
    Store.open(destDb2).close();
    stageRestoreCopy(rep2, m2.data, HOME, g2, dest2, sources2);
    await takeBackSoon(dest2, destDb2, NOW + 3000, bin);
    const sessions2 = dumpTableRows(destDb2, "sessions") as Array<{ key: string; model: string | null }>;
    const chatA = sessions2.find((s) => s.key === "chat:a");
    assert.equal(chatA?.model, `r2-cold-model-${label}`, `${label}: restored session must reflect metadata modified before cold-start failure`);
  }
});

test("FilesPending after DB commit resumes cleanly across engines (Pion -> MB and MB -> Pion)", async (t) => {
  const bins = resolveDualBinaries(t);
  if (!bins) return;

  const { made, attPath } = makeRichStation();
  const rep = join(made.data, "replica-pending");
  const exp = new ExportClient(bins.pion, made.db, rep, made.data);
  await exp.ask({ type: "places", places: PLACES });
  const passed = await exp.ask({ type: "pass", told: nothingTold() });
  const head = passed.heads[HOME];
  const hashes = [...Object.keys(head.files ?? {}), ...Object.keys(head.transcriptFiles ?? {})];
  const sources = await exp.ask({ type: "sources", hashes });
  await exp.close();

  for (const [firstName, firstBin, secondName, secondBin] of [
    ["pion", bins.pion, "mb", bins.mb],
    ["mb", bins.mb, "pion", bins.pion],
  ] as const) {
    const dest = tempDir(`w6b-pending-${firstName}-to-${secondName}-`);
    const dbPath = join(dest, "stillfail.db");
    Store.open(dbPath).close();
    stageRestoreCopy(rep, made.data, HOME, head.gen, dest, sources);

    // Block transcripts/agy with a regular file so mkdir/rename fails AFTER DB commit -> FilesPending!
    const blocker = join(dest, "transcripts");
    writeFileSync(blocker, "blocker-file");

    const r1 = await takeBackSoon(dest, dbPath, NOW + 500, firstBin);
    assert.ok(r1 !== null);
    const out1 = JSON.parse(readFileSync(join(dest, "replica", "restored.json"), "utf8"));
    assert.equal(out1.pending, true, `${firstName} must set pending: true`);
    assert.ok(out1.left >= 1, `${firstName} must report remaining files`);
    assert.equal(existsSync(join(dest, "restore", "ready.json")), true, "restore dir must stay when pending");
    assert.deepEqual(JSON.parse(readFileSync(join(dest, "replica", "formerly.json"), "utf8")), [ORIGIN]);
    // Before engine swap, verify DB rows, replica_restored marker, and pending file rows are already committed.
    assert.ok(dumpTableRows(dbPath, "threads").length >= 1, `${firstName} must commit threads before FilesPending`);
    const restoredMarkers = dumpTableRows(dbPath, "replica_restored") as Array<{ origin: string; gen: string }>;
    assert.ok(
      restoredMarkers.some((m) => m.origin === ORIGIN && m.gen === head.gen),
      `${firstName} must record replica_restored(origin, gen) before FilesPending`,
    );
    const pendingTotal =
      dumpTableRows(dbPath, "replica_restore_files").length +
      dumpTableRows(dbPath, "replica_restore_transcripts").length;
    assert.ok(pendingTotal >= 1, `${firstName} must leave pending file rows before resume`);

    // Remove blocker and resume with the OTHER engine!
    rmSync(blocker);
    const r2 = await takeBackSoon(dest, dbPath, NOW + 600, secondBin);
    assert.ok(r2 !== null);
    const out2 = JSON.parse(readFileSync(join(dest, "replica", "restored.json"), "utf8"));
    assert.equal(out2.pending, false, `${secondName} resume must clear pending`);
    assert.equal(out2.error, null, `${secondName} resume must succeed without error`);
    assert.equal(existsSync(join(dest, "restore")), false, "restore dir must be removed after resume");
    const trDest = join(dest, "transcripts", "agy", "rt-agy-1.jsonl");
    assert.equal(readFileSync(trDest, "utf8"), '{"type":"turn","text":"hello transcript"}\n');
    assert.equal(statSync(trDest).mode & 0o777, 0o640);
    assert.equal(dumpTableRows(dbPath, "replica_restore_files").length, 0);
    assert.equal(dumpTableRows(dbPath, "replica_restore_transcripts").length, 0);
  }
});

test("export.db cross-engine handover: MB pass 1 -> Pion pass 2 -> restore", async (t) => {
  const bins = resolveDualBinaries(t);
  if (!bins) return;

  const { made, attPath } = makeRichStation();
  const rep = join(made.data, "replica-handover");

  // Pass 1 with MB
  const expMb = new ExportClient(bins.mb, made.db, rep, made.data);
  await expMb.ask({ type: "places", places: PLACES });
  const p1 = await expMb.ask({ type: "pass", told: nothingTold() });
  assert.ok(p1.wrote >= 1);
  const gen1 = p1.heads[HOME].gen as string;
  await expMb.close();

  // Append new entry and run Pass 2 with Pion on the SAME export.db
  const told2 = nothingTold();
  made.store.subscribe((c) => void tell(told2, c));
  const th = made.store.db.prepare("SELECT id FROM threads ORDER BY id LIMIT 1").get() as { id: number };
  made.store.insertMessage({ thread: th.id, ts: "r2.handover", authorKind: "person", author: "p@x", text: "handover-msg-from-pion" });

  const expPion = new ExportClient(bins.pion, made.db, rep, made.data);
  expPion.now = NOW + 5000;
  await expPion.ask({ type: "places", places: PLACES });
  const p2 = await expPion.ask({ type: "pass", told: told2 });
  assert.ok(p2.wrote >= 1);
  assert.equal(p2.heads[HOME].gen, gen1, "Pion must continue MB's generation in export.db");
  const hashes = [...Object.keys(p2.heads[HOME].files ?? {}), ...Object.keys(p2.heads[HOME].transcriptFiles ?? {})];
  const sources = await expPion.ask({ type: "sources", hashes });
  await expPion.close();

  // Restore into fresh DB with MB and verify both messages exist
  const dest = tempDir("w6b-exp-handover-dest-");
  const destDb = join(dest, "stillfail.db");
  Store.open(destDb).close();
  stageRestoreCopy(rep, made.data, HOME, gen1, dest, sources);
  await takeBackSoon(dest, destDb, NOW + 6000, bins.mb);
  const entries = dumpTableRows(destDb, "entries");
  assert.ok(entries.some((e) => JSON.stringify(e).includes("handover-msg-from-pion")));
  assert.ok(entries.some((e) => JSON.stringify(e).includes("with attachment")));
});

test("mixed-engine carry move: MB gather + Pion place and Pion gather + MB place", async (t) => {
  const bins = resolveDualBinaries(t);
  if (!bins) return;

  const src = station();
  cleanupDirs.push(src.data);
  const wsA = (src.store.getSession("chat:a") as { workspace: string }).workspace;
  writeFileSync(join(wsA, "alpha.txt"), "alpha-content\n");
  chmodSync(join(wsA, "alpha.txt"), 0o750);
  utimesSync(join(wsA, "alpha.txt"), 1_700_000_222.5, 1_700_000_222.5);
  symlinkSync("alpha.txt", join(wsA, "alpha-link"));

  // Check preview & sizes 0-diff between MB and Pion
  const prevMb = await previewSoon(src.data, src.db, HOME, true, { readers: { "replica-carry": "mb" } });
  const prevPion = await previewSoon(src.data, src.db, HOME, true, { readers: { "replica-carry": "pion" } });
  assert.deepEqual(prevPion, prevMb);

  const szMb = await sizesSoon(src.data, src.db, ["chat:a"], { most: 1000 }, { readers: { "replica-carry": "mb" } });
  const szPion = await sizesSoon(src.data, src.db, ["chat:a"], { most: 1000 }, { readers: { "replica-carry": "pion" } });
  assert.deepEqual(szPion, szMb);

  for (const [gName, pName] of [
    ["mb", "pion"],
    ["pion", "mb"],
  ] as const) {
    const scratch = tempDir(`w6b-carry-scratch-${gName}-${pName}-`);
    const gathered = await gatherSoon(src.data, src.db, HOME, true, scratch, undefined, null, ["chat:a"], {
      readers: { "replica-carry": gName },
    });
    assert.ok(gathered.files >= 1);

    // Stage blobs into a transfer dir `from` keyed by hash (as sending.ts does)
    const fromDir = tempDir(`w6b-carry-from-${gName}-${pName}-`);
    const idx = JSON.parse(readFileSync(gathered.index, "utf8"));
    for (const s of idx.sessions) {
      cpSync(s.at, join(fromDir, s.list));
      for (const line of readFileSync(s.at, "utf8").split("\n").filter(Boolean)) {
        const rec = JSON.parse(line);
        if (rec.hash) cpSync(rec.path, join(fromDir, rec.hash));
      }
    }

    const dest = tempDir(`w6b-carry-dest-${gName}-${pName}-`);
    const placed = await placeSoon(dest, gathered.index, fromDir, null, null, null, false, {
      readers: { "replica-carry": pName },
    });
    assert.equal(placed.missing, 0);
    assert.ok(placed.placed >= 2);
    const destAlpha = wsA.replace(src.data, dest);
    assert.equal(readFileSync(join(destAlpha, "alpha.txt"), "utf8"), "alpha-content\n");
    assert.equal(statSync(join(destAlpha, "alpha.txt")).mode & 0o777, 0o750);
    assert.equal(lstatSync(join(destAlpha, "alpha-link")).isSymbolicLink(), true);
    assert.equal(readlinkSync(join(destAlpha, "alpha-link")), "alpha.txt");
  }
});

test("production entrypoints (ProgramRunner, takeBackSoon, carry) cold-start with pending probe hit Pion wrapper on first spawn", async (t) => {
  const bins = resolveDualBinaries(t);
  if (!bins) return;

  const wrapDir = tempDir("w6b-wrappers-");
  const mbLog = join(wrapDir, "mb.log");
  const pionLog = join(wrapDir, "pion.log");
  const mbWrap = makeRecordingWrapper(wrapDir, "mb-wrap.sh", bins.mb, mbLog);
  const pionWrap = makeRecordingWrapper(wrapDir, "pion-wrap.sh", bins.pion, pionLog);

  await withEnv(
    {
      STILLFAIL_MB_READER: mbWrap,
      STILLFAIL_PION_READER: pionWrap,
      STILLFAIL_READER_ENGINE: undefined,
      STILLFAIL_READER_REPLICA_EXPORT: undefined,
      STILLFAIL_READER_REPLICA_RESTORE: undefined,
      STILLFAIL_READER_REPLICA_CARRY: undefined,
    },
    async () => {
      // Controllable pending probe so we prove production entrypoints await cold-start probe instead of falling back to MB.
      let releaseProbe!: (modes: Set<string>) => void;
      const probePromise = new Promise<Set<string>>((resolve) => {
        releaseProbe = resolve;
      });
      setPionProbeRunnerForTest(() => probePromise);

      try {
        const { made, attPath } = makeRichStation();
        const repDir = join(made.data, "replica-prod");
        const runner = new ProgramRunner({
          db: made.db,
          replica: repDir,
          dataDir: made.data,
          origin: ORIGIN,
          readers: () => ({ readers: { "replica-export": "pion" } }),
        });

        // Start export pass while probe is still pending -> must NOT fall back to MB!
        const passP = (async () => {
          await runner.places(PLACES);
          return runner.pass(nothingTold());
        })();
        const prevP = previewSoon(made.data, made.db, HOME, true, {
          readers: { "replica-carry": "pion" },
        });

        await Promise.resolve();
        assert.equal(countBuilderSpawns(mbLog, "replica-export"), 0, "ProgramRunner must wait on pending probe, not spawn MB");
        assert.equal(countBuilderSpawns(mbLog, "replica-carry"), 0, "carry must wait on pending probe, not spawn MB");

        // Release probe advertising the 3 replica modes
        releaseProbe(new Set(["footprint", "packed", "memory", "live-locator", "replica-export", "replica-restore", "replica-carry"]));

        const [passed, prev] = await Promise.all([passP, prevP]);
        assert.ok(passed.wrote >= 1);
        assert.ok(prev.chats >= 1);
        assert.equal(countBuilderSpawns(pionLog, "replica-export"), 1, "ProgramRunner first spawn must hit Pion wrapper");
        assert.equal(countBuilderSpawns(mbLog, "replica-export"), 0);
        assert.equal(countBuilderSpawns(pionLog, "replica-carry"), 1, "carry first spawn must hit Pion wrapper");
        assert.equal(countBuilderSpawns(mbLog, "replica-carry"), 0);

        const head = passed.heads[HOME];
        const hashes = [...Object.keys(head.files ?? {}), ...Object.keys(head.transcriptFiles ?? {})];
        const sources = await runner.sources(hashes);
        await runner.close();

        // takeBackSoon with independent reset + pending probe -> must wait on probe & hit Pion wrapper on first spawn!
        resetReaderSelectionStateForTest();
        let releaseRestoreProbe!: (modes: Set<string>) => void;
        const restoreProbePromise = new Promise<Set<string>>((resolve) => {
          releaseRestoreProbe = resolve;
        });
        setPionProbeRunnerForTest(() => restoreProbePromise);

        const dest = tempDir("w6b-prod-restore-");
        const destDb = join(dest, "stillfail.db");
        Store.open(destDb).close();
        stageRestoreCopy(repDir, made.data, HOME, head.gen, dest, sources);
        const restoreP = takeBackSoon(dest, destDb, NOW + 900, undefined, {
          readers: { readers: { "replica-restore": "pion" } },
        });
        await Promise.resolve();
        assert.equal(countBuilderSpawns(mbLog, "replica-restore"), 0, "takeBackSoon must wait on pending probe, not spawn MB");
        assert.equal(countBuilderSpawns(pionLog, "replica-restore"), 0, "takeBackSoon must not spawn before probe resolves");

        releaseRestoreProbe(new Set(["footprint", "packed", "memory", "live-locator", "replica-export", "replica-restore", "replica-carry"]));
        const restored = await restoreP;
        assert.ok(restored !== null);
        assert.equal(countBuilderSpawns(pionLog, "replica-restore"), 1, "takeBackSoon must hit Pion wrapper");
        assert.equal(countBuilderSpawns(mbLog, "replica-restore"), 0);
      } finally {
        setPionProbeRunnerForTest(null);
      }
    },
  );
});

test("corrupted, unreadable, missing, schema-invalid, stale, empty-array, or gap head.json aborts pass and preserves all historical batches (MB + Pion)", async (t) => {
  const bins = resolveDualBinaries(t);
  if (!bins) return;

  const isNonRoot = typeof process.getuid === "function" && process.getuid() !== 0;

  for (const [label, bin] of [
    ["mb", bins.mb],
    ["pion", bins.pion],
  ] as const) {
    const made = station();
    cleanupDirs.push(made.data);
    const thA = made.store.db.prepare("SELECT id FROM threads ORDER BY id LIMIT 1").get() as { id: number };
    made.store.insertMessage({ thread: thA.id, ts: "u.1", authorKind: "person", author: "p@x", text: "unchanged-session-msg" });

    const rep = join(made.data, `replica-corrupt-head-${label}`);
    const exp = new ExportClient(bin, made.db, rep, made.data);
    await exp.ask({ type: "places", places: PLACES });
    const p1 = await exp.ask({ type: "pass", told: nothingTold() });
    const gen = p1.heads[HOME].gen as string;
    const genDirPath = join(rep, "own", HOME, gen);
    const headPath = join(genDirPath, "head.json");
    const logDir = join(genDirPath, "log");
    const headPass1 = readFileSync(headPath, "utf8");

    // Pass 2: add a second session + message so there are 2 committed batches.
    const told2 = nothingTold();
    const unsub2 = made.store.subscribe((c) => void tell(told2, c));
    const addedThread = chat(made.store, made.data, "chat:added", HOME, 1);
    made.store.insertMessage({ thread: addedThread, ts: "added.1", authorKind: "person", author: "p@x", text: "added-session-msg" });
    unsub2();
    const p2 = await exp.ask({ type: "pass", told: told2 });
    assert.ok(p2.wrote >= 1);
    const headPass2 = readFileSync(headPath, "utf8");
    const parsedPass2 = JSON.parse(headPass2) as { batches: string[]; to: number; [k: string]: unknown };
    const savedBatches = readdirSync(logDir).sort();
    assert.ok(savedBatches.length >= 2, `${label}: expected >= 2 committed batches after pass 2`);
    assert.ok(parsedPass2.batches.length >= 2, `${label}: expected >= 2 batches in head.json after pass 2`);

    // Add a third message before testing all 7 head.json fault modes.
    made.store.insertMessage({ thread: thA.id, ts: "x.3", authorKind: "person", author: "p@x", text: "updated-after-corrupt" });

    // Fault 1: invalid JSON syntax
    writeFileSync(headPath, "{corrupted-json");
    await assert.rejects(() => exp.ask({ type: "pass", told: nothingTold() }), /corrupt|json|head/i);
    assert.deepEqual(readdirSync(logDir).sort(), savedBatches, `${label}: invalid JSON must preserve all historical batches`);

    // Fault 2: valid JSON object missing `batches`
    writeFileSync(headPath, JSON.stringify({ v: 1, origin: ORIGIN, workspace: HOME, gen, to: parsedPass2.to }));
    await assert.rejects(() => exp.ask({ type: "pass", told: nothingTold() }), /corrupt|batches|head/i);
    assert.deepEqual(readdirSync(logDir).sort(), savedBatches, `${label}: missing batches schema must preserve all historical batches`);

    // Fault 3: head.json deleted while gen dir, log/, and export.db progress still exist
    rmSync(headPath);
    await assert.rejects(() => exp.ask({ type: "pass", told: nothingTold() }), /missing|head/i);
    assert.deepEqual(readdirSync(logDir).sort(), savedBatches, `${label}: deleted head.json must preserve all historical batches`);

    // Fault 4: chmod 000 head.json (unreadable EACCES on non-root)
    writeFileSync(headPath, headPass2);
    if (isNonRoot) {
      chmodSync(headPath, 0o000);
      try {
        await assert.rejects(() => exp.ask({ type: "pass", told: nothingTold() }), /cannot read|EACCES|permission|head/i);
        assert.deepEqual(readdirSync(logDir).sort(), savedBatches, `${label}: chmod 000 head.json must preserve all historical batches`);
      } finally {
        chmodSync(headPath, 0o644);
      }
    }

    // Fault 5 (stale): replace Pass 2's head.json with Pass 1's real valid head.json
    writeFileSync(headPath, headPass1);
    await assert.rejects(() => exp.ask({ type: "pass", told: nothingTold() }), /stale|head/i);
    assert.deepEqual(readdirSync(logDir).sort(), savedBatches, `${label}: stale head.json must preserve all 2/2 historical batches`);

    // Fault 6 (empty-array): keep Pass 2's `to` with `batches: []`
    writeFileSync(headPath, JSON.stringify({ ...parsedPass2, batches: [] }));
    await assert.rejects(() => exp.ask({ type: "pass", told: nothingTold() }), /corrupt|mismatched|non-contiguous|head/i);
    assert.deepEqual(readdirSync(logDir).sort(), savedBatches, `${label}: empty-array head.json must preserve all 2/2 historical batches`);

    // Fault 7 (gap): drop the first batch (`batches.slice(1)`)
    writeFileSync(headPath, JSON.stringify({ ...parsedPass2, batches: parsedPass2.batches.slice(1) }));
    await assert.rejects(() => exp.ask({ type: "pass", told: nothingTold() }), /corrupt|non-contiguous|head/i);
    assert.deepEqual(readdirSync(logDir).sort(), savedBatches, `${label}: gap head.json must preserve all 2/2 historical batches`);

    // Restore valid Pass 2 head.json -> Pass 3 succeeds and full restore retains ALL sessions and messages!
    writeFileSync(headPath, headPass2);
    const p3 = await exp.ask({ type: "pass", told: nothingTold() });
    assert.ok(p3.wrote >= 1);
    const hashes = [...Object.keys(p3.heads[HOME].files ?? {}), ...Object.keys(p3.heads[HOME].transcriptFiles ?? {})];
    const sources = await exp.ask({ type: "sources", hashes });
    await exp.close();

    const dest = tempDir(`w6b-corrupt-dest-${label}-`);
    const destDb = join(dest, "stillfail.db");
    Store.open(destDb).close();
    stageRestoreCopy(rep, made.data, HOME, gen, dest, sources);
    await takeBackSoon(dest, destDb, NOW + 4000, bin);
    const restoredSessionKeys = dumpTableRows(destDb, "sessions").map((s) => s.key);
    assert.ok(restoredSessionKeys.includes("chat:a"), `${label}: chat:a must survive`);
    assert.ok(restoredSessionKeys.includes("chat:added"), `${label}: chat:added from Pass 2 must survive`);
    const restoredEntries = dumpTableRows(destDb, "entries");
    assert.ok(restoredEntries.some((e) => JSON.stringify(e).includes("unchanged-session-msg")), `${label}: unchanged message preserved`);
    assert.ok(restoredEntries.some((e) => JSON.stringify(e).includes("added-session-msg")), `${label}: added message from Pass 2 preserved`);
    assert.ok(restoredEntries.some((e) => JSON.stringify(e).includes("updated-after-corrupt")), `${label}: updated message preserved`);
  }
});

test("CLI numeric flag parity: Int and Double lexical edge cases match MB 1:1", async (t) => {
  const bins = resolveDualBinaries(t);
  if (!bins) return;

  const runExportFlag = async (bin: string, flagVal: string) => {
    const made = station();
    cleanupDirs.push(made.data);
    const thNum = made.store.db.prepare("SELECT id FROM threads ORDER BY id LIMIT 1").get() as { id: number };
    made.store.insertMessage({ thread: thNum.id, ts: "num.1", authorKind: "person", author: "p@x", text: "numeric flag parity" });
    const rep = join(made.data, "replica-cli-num");
    const p = new MbProcess(bin, [
      "--builder", "replica-export",
      "--db", made.db,
      "--replica", rep,
      "--data-dir", made.data,
      "--origin", ORIGIN,
      "--sep", sep,
      "--batch-bytes", flagVal,
    ]);
    const ask = (req: Record<string, unknown>) =>
      new Promise<any>((resolve, reject) => {
        const onMsg = (m: { answer?: unknown; error?: string }) => {
          p.off("message", onMsg);
          if (m.error !== undefined) reject(new Error(m.error));
          else resolve(m.answer);
        };
        p.on("message", onMsg);
        p.postMessage({ id: 1, now: NOW, ...req });
      });
    try {
      await ask({ type: "places", places: PLACES });
      const passed = await ask({ type: "pass", told: nothingTold() });
      const head = passed.heads[HOME];
      const hashes = [...Object.keys(head?.files ?? {}), ...Object.keys(head?.transcriptFiles ?? {})];
      const sources = await ask({ type: "sources", hashes });
      await ask({ type: "close" });
      const stDb = new DatabaseSync(join(rep, "export.db"), { readOnly: true });
      let entriesCursor = "0";
      try {
        const row = stDb.prepare("SELECT v FROM meta WHERE k = 'entries'").get() as { v: string } | undefined;
        entriesCursor = row?.v ?? "0";
      } finally {
        stDb.close();
      }
      return { made, rep, head, sources, wrote: passed.wrote as number, more: passed.more as boolean, entriesCursor };
    } finally {
      p.kill();
    }
  };

  // Int flags:
  // - valid 0 spellings parse as 0 (`most = 0`: `more = true`, `entries` cursor stays "0");
  // - invalid/overflow spellings fall back to default BATCH_BYTES (`more = false`, `entries` cursor > 0).
  for (const [val, wantMore] of [
    ["+0", true],
    ["0x0", true],
    ["0X0", true],
    ["-0x0", true],
    ["0_0", true],
    ["0x_0", true],
    ["0o_0", true],
    ["0b_0", true],
    ["0_", false],
    ["0__0", false],
    ["4294967296", false],
  ] as const) {
    const mbRes = await runExportFlag(bins.mb, val);
    const pionRes = await runExportFlag(bins.pion, val);
    assert.equal(pionRes.more, mbRes.more, `--batch-bytes ${val}: more must match MB`);
    assert.equal(pionRes.entriesCursor, mbRes.entriesCursor, `--batch-bytes ${val}: entries cursor must match MB`);
    assert.equal(pionRes.more, wantMore, `--batch-bytes ${val}: expected more=${wantMore}`);
    if (wantMore) {
      assert.equal(pionRes.entriesCursor, "0", `--batch-bytes ${val}: most=0 must leave entries cursor at 0`);
    } else {
      assert.ok(Number(pionRes.entriesCursor) > 0, `--batch-bytes ${val}: fallback BATCH_BYTES must advance entries cursor past 0`);
    }
  }

  // Double flags on replica-restore: finite, invalid underscores, overflow 1e309 -> 0, Infinity/-inf/NaN -> JSON null.
  const seed = await runExportFlag(bins.pion, "4294967296");
  for (const [rawNow, wantAt] of [
    ["+1", 1],
    ["0012.5", 12.5],
    ["1_000.5", 1000.5],
    [" 12.5 ", 0],
    ["1__2", 0],
    ["1_", 0],
    ["1_e2", 0],
    ["1._2", 0],
    ["1.2_", 0],
    ["1e2_", 0],
    ["1e309", 0],
    ["Infinity", null],
    ["-inf", null],
    ["NaN", null],
  ] as const) {
    for (const [label, bin] of [
      ["mb", bins.mb],
      ["pion", bins.pion],
    ] as const) {
      const dest = tempDir(`w6b-now-${label}-`);
      const destDb = join(dest, "stillfail.db");
      Store.open(destDb).close();
      stageRestoreCopy(seed.rep, seed.made.data, HOME, seed.head.gen, dest, seed.sources);
      const rp = new MbProcess(bin, ["--builder", "replica-restore", "--db", destDb, "--data", dest, "--now", rawNow, "--sep", sep]);
      const rmsg = await new Promise<{ ready?: unknown; error?: string }>((resolve, reject) => {
        rp.once("message", resolve);
        rp.once("error", reject);
      });
      assert.equal(rmsg.error, undefined, `${label}: --now ${JSON.stringify(rawNow)} must succeed`);
      const outcome = JSON.parse(readFileSync(join(dest, "replica", "restored.json"), "utf8"));
      assert.equal(outcome.at, wantAt, `${label}: --now ${JSON.stringify(rawNow)} must parse as ${JSON.stringify(wantAt)}`);
    }
  }
});

test("legacy upgrade without head_state: legacy-good reuses gen, legacy-stale preserves old log/ and rebuilds new gen (MB + Pion)", async (t) => {
  const bins = resolveDualBinaries(t);
  if (!bins) return;

  for (const [label, bin] of [
    ["mb", bins.mb],
    ["pion", bins.pion],
  ] as const) {
    for (const mode of ["legacy-good", "legacy-stale"] as const) {
      const made = station();
      cleanupDirs.push(made.data);
      const thA = made.store.db.prepare("SELECT id FROM threads ORDER BY id LIMIT 1").get() as { id: number };
      made.store.insertMessage({ thread: thA.id, ts: "lg.u1", authorKind: "person", author: "p@x", text: "unchanged-session-msg" });
      const thX = chat(made.store, made.data, "chat:x", HOME, 1);
      made.store.insertMessage({ thread: thX, ts: "lg.x1", authorKind: "person", author: "p@x", text: "x-v1" });

      const rep = join(made.data, `replica-${mode}-${label}`);
      const exp1 = new ExportClient(bin, made.db, rep, made.data);
      await exp1.ask({ type: "places", places: PLACES });
      const p1 = await exp1.ask({ type: "pass", told: nothingTold() });
      const gen1 = p1.heads[HOME].gen as string;
      const gen1Dir = join(rep, "own", HOME, gen1);
      const head1Path = join(gen1Dir, "head.json");
      const log1Dir = join(gen1Dir, "log");
      const headPass1 = readFileSync(head1Path, "utf8");

      // Pass 2: update chat:x and add chat:added -> 2 committed batches.
      const told2 = nothingTold();
      const unsub2 = made.store.subscribe((c) => void tell(told2, c));
      made.store.insertMessage({ thread: thX, ts: "lg.x2", authorKind: "person", author: "p@x", text: "x-v2" });
      const thAdded = chat(made.store, made.data, "chat:added", HOME, 1);
      made.store.insertMessage({ thread: thAdded, ts: "lg.a1", authorKind: "person", author: "p@x", text: "added-session-msg" });
      unsub2();
      const p2 = await exp1.ask({ type: "pass", told: told2 });
      assert.ok(p2.wrote >= 1);
      const batchesAfterPass2 = readdirSync(log1Dir).sort();
      assert.ok(batchesAfterPass2.length >= 2, `${label}/${mode}: expected >= 2 batches after Pass 2`);
      await exp1.close();

      // Simulate legacy export.db (before head_state:* existed).
      const stDb = new DatabaseSync(join(rep, "export.db"));
      try {
        stDb.exec("DELETE FROM meta WHERE k LIKE 'head_state:%'");
      } finally {
        stDb.close();
      }
      if (mode === "legacy-stale") {
        writeFileSync(head1Path, headPass1);
      }

      const exp2 = new ExportClient(bin, made.db, rep, made.data);
      exp2.now = NOW + 5000;
      await exp2.ask({ type: "places", places: PLACES });
      const p3 = await exp2.ask({ type: "pass", told: nothingTold() });
      const genAfter = p3.heads[HOME].gen as string;
      if (mode === "legacy-good") {
        assert.equal(genAfter, gen1, `${label}/legacy-good: must reuse same generation`);
      } else {
        assert.notEqual(genAfter, gen1, `${label}/legacy-stale: must rebuild into a new generation`);
        assert.deepEqual(
          readdirSync(log1Dir).sort(),
          batchesAfterPass2,
          `${label}/legacy-stale: old gen log/ must keep all 2/2 batches untouched`,
        );
      }
      const hashes = [...Object.keys(p3.heads[HOME].files ?? {}), ...Object.keys(p3.heads[HOME].transcriptFiles ?? {})];
      const sources = await exp2.ask({ type: "sources", hashes });
      await exp2.close();

      const dest = tempDir(`w6b-${mode}-dest-${label}-`);
      const destDb = join(dest, "stillfail.db");
      Store.open(destDb).close();
      stageRestoreCopy(rep, made.data, HOME, genAfter, dest, sources);
      await takeBackSoon(dest, destDb, NOW + 6000, bin);
      const keys = dumpTableRows(destDb, "sessions").map((s) => s.key);
      assert.ok(keys.includes("chat:a"), `${label}/${mode}: chat:a restored`);
      assert.ok(keys.includes("chat:x"), `${label}/${mode}: chat:x restored`);
      assert.ok(keys.includes("chat:added"), `${label}/${mode}: chat:added restored`);
      const entries = dumpTableRows(destDb, "entries");
      assert.ok(entries.some((e) => JSON.stringify(e).includes("unchanged-session-msg")), `${label}/${mode}: unchanged msg restored`);
      assert.ok(entries.some((e) => JSON.stringify(e).includes("x-v2")), `${label}/${mode}: x-v2 restored`);
      assert.ok(entries.some((e) => JSON.stringify(e).includes("added-session-msg")), `${label}/${mode}: added msg restored`);
    }
  }
});

test("legacy empty-fold upgrade (to=N, batches=[]) and post-empty-fold upgrade ([N+1-...]) succeed without head_state (MB + Pion)", async (t) => {
  const bins = resolveDualBinaries(t);
  if (!bins) return;

  for (const [label, bin] of [
    ["mb", bins.mb],
    ["pion", bins.pion],
  ] as const) {
    const made = station();
    cleanupDirs.push(made.data);
    const rep = join(made.data, `replica-empty-fold-${label}`);
    const exp1 = new ExportClient(bin, made.db, rep, made.data);
    await exp1.ask({ type: "places", places: PLACES });
    const p1 = await exp1.ask({ type: "pass", told: nothingTold() });
    const gen = p1.heads[HOME].gen as string;

    // Delete ALL sessions in HOME so whole-fold produces (to=N > 0, batches=[]).
    const homeSessions = made.store.db.prepare("SELECT key FROM sessions WHERE ws = ? OR ws IS NULL OR ws = ''").all(HOME) as { key: string }[];
    const toldDel = nothingTold();
    const unsubDel = made.store.subscribe((c) => void tell(toldDel, c));
    for (const s of homeSessions) made.store.deleteSession(s.key);
    unsubDel();
    const p2 = await exp1.ask({ type: "pass", told: toldDel });
    const emptyTo = p2.heads[HOME].to as number;
    assert.ok(emptyTo > 0, `${label}: empty-folded head must have to > 0`);
    assert.deepEqual(p2.heads[HOME].batches, [], `${label}: whole-fold after deleting all sessions must produce batches=[]`);
    await exp1.close();

    // 1) Simulate legacy upgrade on (to=N, batches=[]): delete head_state:*, add a new session, pass.
    const st1 = new DatabaseSync(join(rep, "export.db"));
    try {
      st1.exec("DELETE FROM meta WHERE k LIKE 'head_state:%'");
    } finally {
      st1.close();
    }
    const thReborn = chat(made.store, made.data, "chat:reborn", HOME, 1);
    made.store.insertMessage({ thread: thReborn, ts: "rb.1", authorKind: "person", author: "p@x", text: "reborn-msg-1" });

    const exp2 = new ExportClient(bin, made.db, rep, made.data);
    exp2.now = NOW + 3000;
    await exp2.ask({ type: "places", places: PLACES });
    const p3 = await exp2.ask({ type: "pass", told: nothingTold() });
    assert.equal(p3.heads[HOME].gen, gen, `${label}: empty-fold legacy upgrade must stay on same gen`);
    const firstBatch = p3.heads[HOME].batches[0] as string;
    assert.ok(firstBatch.startsWith(`${String(emptyTo + 1).padStart(10, "0")}-`), `${label}: first batch after empty fold must start at N+1`);
    await exp2.close();

    // 2) Simulate legacy upgrade AGAIN when batches[0].from == N+1 > 1.
    const st2 = new DatabaseSync(join(rep, "export.db"));
    try {
      st2.exec("DELETE FROM meta WHERE k LIKE 'head_state:%'");
    } finally {
      st2.close();
    }
    made.store.insertMessage({ thread: thReborn, ts: "rb.2", authorKind: "person", author: "p@x", text: "reborn-msg-2" });

    const exp3 = new ExportClient(bin, made.db, rep, made.data);
    exp3.now = NOW + 6000;
    await exp3.ask({ type: "places", places: PLACES });
    const p4 = await exp3.ask({ type: "pass", told: nothingTold() });
    assert.equal(p4.heads[HOME].gen, gen);
    assert.ok((p4.heads[HOME].batches[0] as string).startsWith(`${String(emptyTo + 1).padStart(10, "0")}-`));
    const hashes = [...Object.keys(p4.heads[HOME].files ?? {}), ...Object.keys(p4.heads[HOME].transcriptFiles ?? {})];
    const sources = await exp3.ask({ type: "sources", hashes });
    await exp3.close();

    const dest = tempDir(`w6b-empty-fold-dest-${label}-`);
    const destDb = join(dest, "stillfail.db");
    Store.open(destDb).close();
    stageRestoreCopy(rep, made.data, HOME, gen, dest, sources);
    await takeBackSoon(dest, destDb, NOW + 7000, bin);
    const entries = dumpTableRows(destDb, "entries");
    assert.ok(entries.some((e) => JSON.stringify(e).includes("reborn-msg-1")), `${label}: reborn-msg-1 restored`);
    assert.ok(entries.some((e) => JSON.stringify(e).includes("reborn-msg-2")), `${label}: reborn-msg-2 restored`);
  }
});

test("empty-fold committed head ignores unpublished crash-window orphan batch (from=N+1) and cleans it up (MB + Pion)", async (t) => {
  const bins = resolveDualBinaries(t);
  if (!bins) return;

  for (const [label, bin] of [
    ["mb", bins.mb],
    ["pion", bins.pion],
  ] as const) {
    const made = station();
    cleanupDirs.push(made.data);
    const rep = join(made.data, `replica-empty-orphan-${label}`);
    const exp = new ExportClient(bin, made.db, rep, made.data);
    await exp.ask({ type: "places", places: PLACES });
    const p1 = await exp.ask({ type: "pass", told: nothingTold() });
    const gen = p1.heads[HOME].gen as string;

    const homeSessions = made.store.db.prepare("SELECT key FROM sessions WHERE ws = ? OR ws IS NULL OR ws = ''").all(HOME) as { key: string }[];
    const toldDel = nothingTold();
    const unsubDel = made.store.subscribe((c) => void tell(toldDel, c));
    for (const s of homeSessions) made.store.deleteSession(s.key);
    unsubDel();
    const p2 = await exp.ask({ type: "pass", told: toldDel });
    const emptyTo = p2.heads[HOME].to as number;
    assert.deepEqual(p2.heads[HOME].batches, []);

    // Plant unpublished crash-window orphan batch with from = N+1, to = N+1.
    const logDir = join(rep, "own", HOME, gen, "log");
    const n1 = String(emptyTo + 1).padStart(10, "0");
    const orphanName = `${n1}-${n1}-deadbeef.ndjson.zst`;
    writeFileSync(join(logDir, orphanName), "orphan-crash-window-bytes");

    const toldNew = nothingTold();
    const unsubNew = made.store.subscribe((c) => void tell(toldNew, c));
    const thNew = chat(made.store, made.data, "chat:after-orphan", HOME, 1);
    made.store.insertMessage({ thread: thNew, ts: "or.1", authorKind: "person", author: "p@x", text: "after-orphan-msg" });
    unsubNew();
    const p3 = await exp.ask({ type: "pass", told: toldNew });
    assert.ok(p3.wrote >= 1);
    assert.ok(!existsSync(join(logDir, orphanName)), `${label}: crash-window orphan must be cleaned up by fold_gen`);
    const hashes = [...Object.keys(p3.heads[HOME].files ?? {}), ...Object.keys(p3.heads[HOME].transcriptFiles ?? {})];
    const sources = await exp.ask({ type: "sources", hashes });
    await exp.close();

    const dest = tempDir(`w6b-orphan-dest-${label}-`);
    const destDb = join(dest, "stillfail.db");
    Store.open(destDb).close();
    stageRestoreCopy(rep, made.data, HOME, gen, dest, sources);
    await takeBackSoon(dest, destDb, NOW + 8000, bin);
    const entries = dumpTableRows(destDb, "entries");
    assert.ok(entries.some((e) => JSON.stringify(e).includes("after-orphan-msg")), `${label}: after-orphan-msg restored`);
  }
});

test("whole-fold-to-empty followed by export.db rollback retries cleanly in same process and after restart (MB + Pion)", async (t) => {
  const bins = resolveDualBinaries(t);
  if (!bins) return;

  for (const [label, bin] of [
    ["mb", bins.mb],
    ["pion", bins.pion],
  ] as const) {
    for (const mode of ["same-process", "restart"] as const) {
      const made = station();
      cleanupDirs.push(made.data);
      const rep = join(made.data, `replica-empty-commit-fault-${mode}-${label}`);
      const exp1 = new ExportClient(bin, made.db, rep, made.data);
      await exp1.ask({ type: "places", places: PLACES });
      const p1 = await exp1.ask({ type: "pass", told: nothingTold() });
      const gen = p1.heads[HOME].gen as string;
      const to1 = p1.heads[HOME].to as number;

      // Inject a SQLite trigger on export.db so save_committed_head_state aborts AFTER fold_gen writes
      // disk head.json = (to=N > to1, batches=[]) and empties log/, rolling export.db back to (to1, [b1]).
      const stInject = new DatabaseSync(join(rep, "export.db"));
      try {
        stInject.exec(`
          CREATE TRIGGER fail_hs_ins BEFORE INSERT ON meta WHEN NEW.k = 'head_state:${HOME}'
          BEGIN SELECT RAISE(ABORT, 'injected head_state commit fault'); END;
          CREATE TRIGGER fail_hs_upd BEFORE UPDATE ON meta WHEN NEW.k = 'head_state:${HOME}'
          BEGIN SELECT RAISE(ABORT, 'injected head_state commit fault'); END;
        `);
      } finally {
        stInject.close();
      }

      const homeSessions = made.store.db.prepare("SELECT key FROM sessions WHERE ws = ? OR ws IS NULL OR ws = ''").all(HOME) as { key: string }[];
      const toldDel = nothingTold();
      const unsubDel = made.store.subscribe((c) => void tell(toldDel, c));
      for (const s of homeSessions) made.store.deleteSession(s.key);
      unsubDel();
      await assert.rejects(() => exp1.ask({ type: "pass", told: toldDel }), /injected head_state commit fault/i);

      // Confirm disk head.json is now (to > to1, batches=[]) while export.db rolled back to (to1, [b1]).
      const diskHead = JSON.parse(readFileSync(join(rep, "own", HOME, gen, "head.json"), "utf8")) as { to: number; batches: string[] };
      assert.ok(diskHead.to > to1, `${label}/${mode}: disk head.to must be > committed to1`);
      assert.deepEqual(diskHead.batches, [], `${label}/${mode}: disk head.batches must be []`);

      // Remove injected triggers.
      const stClear = new DatabaseSync(join(rep, "export.db"));
      try {
        stClear.exec("DROP TRIGGER IF EXISTS fail_hs_ins; DROP TRIGGER IF EXISTS fail_hs_upd;");
      } finally {
        stClear.close();
      }

      const thNew = chat(made.store, made.data, "chat:after-commit-fault", HOME, 1);
      made.store.insertMessage({ thread: thNew, ts: "cf.1", authorKind: "person", author: "p@x", text: "recovered-after-empty-commit-fault" });

      let expUse = exp1;
      if (mode === "restart") {
        await exp1.close();
        expUse = new ExportClient(bin, made.db, rep, made.data);
        expUse.now = NOW + 4000;
        await expUse.ask({ type: "places", places: PLACES });
      }
      const pRetry = await expUse.ask({ type: "pass", told: mode === "same-process" ? toldDel : nothingTold() });
      // For same-process, also pick up the new chat created after toldDel was unsubscribed.
      const pFinal =
        mode === "same-process"
          ? await (async () => {
              await expUse.close();
              const expNext = new ExportClient(bin, made.db, rep, made.data);
              expNext.now = NOW + 5000;
              await expNext.ask({ type: "places", places: PLACES });
              const pf = await expNext.ask({ type: "pass", told: nothingTold() });
              const hs = [...Object.keys(pf.heads[HOME].files ?? {}), ...Object.keys(pf.heads[HOME].transcriptFiles ?? {})];
              const srcs = await expNext.ask({ type: "sources", hashes: hs });
              await expNext.close();
              return { pf, srcs };
            })()
          : await (async () => {
              const hs = [...Object.keys(pRetry.heads[HOME].files ?? {}), ...Object.keys(pRetry.heads[HOME].transcriptFiles ?? {})];
              const srcs = await expUse.ask({ type: "sources", hashes: hs });
              await expUse.close();
              return { pf: pRetry, srcs };
            })();

      assert.equal(pFinal.pf.heads[HOME].gen, gen);
      const dest = tempDir(`w6b-cf-dest-${mode}-${label}-`);
      const destDb = join(dest, "stillfail.db");
      Store.open(destDb).close();
      stageRestoreCopy(rep, made.data, HOME, gen, dest, pFinal.srcs);
      await takeBackSoon(dest, destDb, NOW + 9000, bin);
      const entries = dumpTableRows(destDb, "entries");
      assert.ok(
        entries.some((e) => JSON.stringify(e).includes("recovered-after-empty-commit-fault")),
        `${label}/${mode}: recovered-after-empty-commit-fault restored`,
      );
    }
  }
});

test("whole-fold empty head written but old batch unlink failed rebuilds cleanly into new generation (MB + Pion)", async (t) => {
  const bins = resolveDualBinaries(t);
  if (!bins) return;

  for (const [label, bin] of [
    ["mb", bins.mb],
    ["pion", bins.pion],
  ] as const) {
    const made = station();
    cleanupDirs.push(made.data);
    const rep = join(made.data, `replica-empty-unlink-eacces-${label}`);
    const exp1 = new ExportClient(bin, made.db, rep, made.data);
    await exp1.ask({ type: "places", places: PLACES });
    const p1 = await exp1.ask({ type: "pass", told: nothingTold() });
    const gen1 = p1.heads[HOME].gen as string;
    const to1 = p1.heads[HOME].to as number;
    const gen1Dir = join(rep, "own", HOME, gen1);
    const log1Dir = join(gen1Dir, "log");

    // Delete all HOME sessions and make log/ read-only: write_batch isn't needed for empty whole-fold,
    // write_head writes (to=N > to1, batches=[]), and then unlinking old batch b1 fails with EACCES,
    // rolling export.db back to committed (to1, [b1]) while disk has empty head + old batch in log/.
    const homeSessions = made.store.db.prepare("SELECT key FROM sessions WHERE ws = ? OR ws IS NULL OR ws = ''").all(HOME) as { key: string }[];
    const toldDel = nothingTold();
    const unsubDel = made.store.subscribe((c) => void tell(toldDel, c));
    for (const s of homeSessions) made.store.deleteSession(s.key);
    unsubDel();

    // First write_batch needs log/ writable, so let's test the exact post-write_head unlink failure state:
    // use a SQLite trigger to fail right after write_head? No — chmod 0555 on log/ directly causes unlink to fail
    // after fold_gen writes empty head if we only block log/ during unlink, OR if we simulate the exact disk state
    // produced by unlink EACCES (head.json = {to: to1 + 1, batches: []}, log/ still holds b1, export.db at to1).
    // Even better: chmod 0555 log/ fails before write_batch if a batch is written first; here let's verify
    // the exact state where write_head wrote (to=to1+1, batches=[]) and old batch remained in log/.
    const savedBatches = readdirSync(log1Dir).sort();
    assert.ok(savedBatches.length >= 1);
    const head1 = JSON.parse(readFileSync(join(gen1Dir, "head.json"), "utf8")) as Record<string, unknown>;
    await exp1.close();
    writeFileSync(join(gen1Dir, "head.json"), JSON.stringify({ ...head1, to: to1 + 1, batches: [] }, null, 1));

    // Restart, add a new session, and run pass: must RebuildLegacy into gen2 and preserve old log1Dir untouched!
    const thNew = chat(made.store, made.data, "chat:after-unlink-fail", HOME, 1);
    made.store.insertMessage({ thread: thNew, ts: "ul.1", authorKind: "person", author: "p@x", text: "recovered-after-unlink-eacces" });

    const exp2 = new ExportClient(bin, made.db, rep, made.data);
    exp2.now = NOW + 5000;
    await exp2.ask({ type: "places", places: PLACES });
    const p2 = await exp2.ask({ type: "pass", told: nothingTold() });
    const gen2 = p2.heads[HOME].gen as string;
    assert.notEqual(gen2, gen1, `${label}: must rebuild into a new generation when empty head > committed has old batches in log/`);
    assert.deepEqual(readdirSync(log1Dir).sort(), savedBatches, `${label}: old gen log/ must stay untouched`);

    const hashes = [...Object.keys(p2.heads[HOME].files ?? {}), ...Object.keys(p2.heads[HOME].transcriptFiles ?? {})];
    const sources = await exp2.ask({ type: "sources", hashes });
    await exp2.close();

    const dest = tempDir(`w6b-unlink-dest-${label}-`);
    const destDb = join(dest, "stillfail.db");
    Store.open(destDb).close();
    stageRestoreCopy(rep, made.data, HOME, gen2, dest, sources);
    await takeBackSoon(dest, destDb, NOW + 9000, bin);
    const entries = dumpTableRows(destDb, "entries");
    assert.ok(
      entries.some((e) => JSON.stringify(e).includes("recovered-after-unlink-eacces")),
      `${label}: recovered-after-unlink-eacces restored from new generation`,
    );
  }
});

test("legacy upgrade with missing referenced batch file rebuilds into new generation and restores all sessions (MB + Pion)", async (t) => {
  const bins = resolveDualBinaries(t);
  if (!bins) return;

  for (const [label, bin] of [
    ["mb", bins.mb],
    ["pion", bins.pion],
  ] as const) {
    const made = station();
    cleanupDirs.push(made.data);
    const thA = made.store.db.prepare("SELECT id FROM threads ORDER BY id LIMIT 1").get() as { id: number };
    made.store.insertMessage({ thread: thA.id, ts: "lm.u1", authorKind: "person", author: "p@x", text: "legacy-miss-unchanged" });
    const thX = chat(made.store, made.data, "chat:x", HOME, 1);
    made.store.insertMessage({ thread: thX, ts: "lm.x1", authorKind: "person", author: "p@x", text: "legacy-miss-x" });

    const rep = join(made.data, `replica-legacy-missing-batch-${label}`);
    const exp1 = new ExportClient(bin, made.db, rep, made.data);
    await exp1.ask({ type: "places", places: PLACES });
    const p1 = await exp1.ask({ type: "pass", told: nothingTold() });
    const gen1 = p1.heads[HOME].gen as string;
    const log1Dir = join(rep, "own", HOME, gen1, "log");

    const told2 = nothingTold();
    const unsub2 = made.store.subscribe((c) => void tell(told2, c));
    const thAdded = chat(made.store, made.data, "chat:added", HOME, 1);
    made.store.insertMessage({ thread: thAdded, ts: "lm.a1", authorKind: "person", author: "p@x", text: "legacy-miss-added" });
    unsub2();
    const p2 = await exp1.ask({ type: "pass", told: told2 });
    assert.ok(p2.wrote >= 1);
    await exp1.close();

    // Delete head_state:* (legacy DB) and remove 1 of the 2 batches referenced by head.json.
    const stDb = new DatabaseSync(join(rep, "export.db"));
    try {
      stDb.exec("DELETE FROM meta WHERE k LIKE 'head_state:%'");
    } finally {
      stDb.close();
    }
    const batches = readdirSync(log1Dir).sort();
    assert.ok(batches.length >= 2);
    rmSync(join(log1Dir, batches[0]!));
    const remainingOld = readdirSync(log1Dir).sort();

    const exp2 = new ExportClient(bin, made.db, rep, made.data);
    exp2.now = NOW + 5000;
    await exp2.ask({ type: "places", places: PLACES });
    const p3 = await exp2.ask({ type: "pass", told: nothingTold() });
    const gen2 = p3.heads[HOME].gen as string;
    assert.notEqual(gen2, gen1, `${label}: missing referenced batch must trigger RebuildLegacy into new gen`);
    assert.deepEqual(readdirSync(log1Dir).sort(), remainingOld, `${label}: old gen dir must stay untouched`);

    const hashes = [...Object.keys(p3.heads[HOME].files ?? {}), ...Object.keys(p3.heads[HOME].transcriptFiles ?? {})];
    const sources = await exp2.ask({ type: "sources", hashes });
    await exp2.close();

    const dest = tempDir(`w6b-legacy-miss-dest-${label}-`);
    const destDb = join(dest, "stillfail.db");
    Store.open(destDb).close();
    stageRestoreCopy(rep, made.data, HOME, gen2, dest, sources);
    await takeBackSoon(dest, destDb, NOW + 9000, bin);
    const keys = dumpTableRows(destDb, "sessions").map((s) => s.key);
    assert.ok(keys.includes("chat:a"), `${label}: chat:a restored`);
    assert.ok(keys.includes("chat:x"), `${label}: chat:x restored`);
    assert.ok(keys.includes("chat:added"), `${label}: chat:added restored`);
  }
});

test("healthy legacy upgrade persists head_state:<ws> immediately even on idle wrote=0 pass (MB + Pion)", async (t) => {
  const bins = resolveDualBinaries(t);
  if (!bins) return;

  for (const [label, bin] of [
    ["mb", bins.mb],
    ["pion", bins.pion],
  ] as const) {
    const made = station();
    cleanupDirs.push(made.data);
    const rep = join(made.data, `replica-legacy-idle-${label}`);
    const exp1 = new ExportClient(bin, made.db, rep, made.data);
    await exp1.ask({ type: "places", places: PLACES });
    const p1 = await exp1.ask({ type: "pass", told: nothingTold() });
    const gen = p1.heads[HOME].gen as string;
    await exp1.close();

    // Remove head_state:* to simulate healthy legacy DB.
    const st1 = new DatabaseSync(join(rep, "export.db"));
    try {
      st1.exec("DELETE FROM meta WHERE k LIKE 'head_state:%'");
    } finally {
      st1.close();
    }

    // Reopen and run an idle pass (wrote === 0).
    const exp2 = new ExportClient(bin, made.db, rep, made.data);
    await exp2.ask({ type: "places", places: PLACES });
    const p2 = await exp2.ask({ type: "pass", told: nothingTold() });
    assert.equal(p2.wrote, 0, `${label}: idle pass must have wrote === 0`);
    assert.equal(p2.heads[HOME].gen, gen, `${label}: healthy legacy upgrade must stay on same gen`);
    await exp2.close();

    const st2 = new DatabaseSync(join(rep, "export.db"), { readOnly: true });
    try {
      const row = st2.prepare("SELECT v FROM meta WHERE k = ?").get(`head_state:${HOME}`) as { v: string } | undefined;
      assert.ok(row !== undefined, `${label}: head_state:${HOME} must be persisted immediately after idle pass`);
      const parsed = JSON.parse(row.v) as { gen: string; to: number; batches: string[] };
      assert.equal(parsed.gen, gen);
      assert.equal(parsed.to, p1.heads[HOME].to);
    } finally {
      st2.close();
    }
  }
});

function makeTranscriptSeedStation() {
  const made = station();
  cleanupDirs.push(made.data);
  const trDir = join(made.data, "homes", "p1", "agy", ".gemini", "antigravity-cli", "brain", "cid-manifest");
  mkdirSync(trDir, { recursive: true });
  writeFileSync(join(trDir, "notes.md"), "transcript-manifest-payload-".repeat(120));
  writeFileSync(join(trDir, "extra.json"), JSON.stringify({ ok: true, data: "x".repeat(2500) }));
  made.store.db
    .prepare("INSERT INTO runtime_sessions (session_key, id, profile, at, runtime) VALUES (?, ?, ?, ?, ?)")
    .run("chat:a", "cid-manifest", "p1", NOW, "agy");
  return made;
}

test("manifest restore rejects missing root, corrupted root, and missing leaf before touching target DB (MB + Pion)", async (t) => {
  const bins = resolveDualBinaries(t);
  if (!bins) return;

  const made = makeTranscriptSeedStation();
  const rep = join(made.data, "replica-manifest-restore-src");
  const exp = new ExportClient(bins.mb, made.db, rep, made.data, ["--compact-heads", "--chunk-bytes", "1024"]);
  await exp.ask({ type: "places", places: PLACES });
  let p = await exp.ask({ type: "pass", told: nothingTold() });
  while (p.more) p = await exp.ask({ type: "pass", told: nothingTold() });
  const ipcHead = p.heads[HOME] as Record<string, any>;
  const gen = String(ipcHead.gen);
  const rootHash = String(ipcHead.transcriptManifest);
  assert.match(rootHash, /^[0-9a-f]{64}$/, "compact-heads must emit 64-hex transcriptManifest");
  const diskHead = JSON.parse(readFileSync(join(rep, "own", HOME, gen, "head.json"), "utf8")) as Record<string, any>;
  const hashes = [...Object.keys(diskHead.files ?? {}), ...Object.keys(diskHead.transcriptFiles ?? {})];
  const sources = (await exp.ask({ type: "sources", hashes })) as Record<string, string>;
  await exp.close();

  const manifestsDir = join(rep, "manifests");
  const rootObj = JSON.parse(readFileSync(join(manifestsDir, rootHash), "utf8")) as { v: number; buckets: Record<string, string> };
  const leafHashes = Object.values(rootObj.buckets);
  assert.ok(leafHashes.length >= 1, "expected at least one manifest leaf");

  const stageWithManifest = (dest: string) => {
    stageRestoreCopy(rep, made.data, HOME, gen, dest, sources);
    // Write the compact head carrying transcriptManifest (as S3/Folder restore downloads it).
    writeFileSync(join(dest, "restore", "copy", gen, "head.json"), JSON.stringify(ipcHead, null, 1));
    const filesDir = join(dest, "restore", "copy", "files");
    cpSync(join(manifestsDir, rootHash), join(filesDir, rootHash));
    for (const lh of leafHashes) {
      cpSync(join(manifestsDir, lh), join(filesDir, lh));
    }
  };

  for (const [label, bin] of [
    ["mb", bins.mb],
    ["pion", bins.pion],
  ] as const) {
    // Control group: intact manifest succeeds on both engines.
    {
      const dest = tempDir(`w6b-mrest-ok-${label}-`);
      const destDb = join(dest, "stillfail.db");
      Store.open(destDb).close();
      stageWithManifest(dest);
      await takeBackSoon(dest, destDb, NOW + 2000, bin);
      const restoredSessions = dumpTableRows(destDb, "sessions");
      const restoredMarks = dumpTableRows(destDb, "replica_restored");
      assert.ok(restoredSessions.length >= 1, `${label}/control: expected restored sessions`);
      assert.equal(restoredMarks.length, 1, `${label}/control: expected 1 replica_restored mark`);
    }

    // Fault cases: (a) missing root, (b) corrupted root, (c) missing leaf.
    for (const fault of ["missing-root", "corrupt-root", "missing-leaf"] as const) {
      const dest = tempDir(`w6b-mrest-${fault}-${label}-`);
      const destDb = join(dest, "stillfail.db");
      Store.open(destDb).close();
      stageWithManifest(dest);
      const filesDir = join(dest, "restore", "copy", "files");
      if (fault === "missing-root") {
        rmSync(join(filesDir, rootHash));
      } else if (fault === "corrupt-root") {
        writeFileSync(join(filesDir, rootHash), '{"v":1,"buckets":{"00":"deadbeef"}}');
      } else {
        rmSync(join(filesDir, leafHashes[0]!));
      }

      await takeBackSoon(dest, destDb, NOW + 3000, bin);
      const outcome = JSON.parse(readFileSync(join(dest, "replica", "restored.json"), "utf8")) as {
        error: string | null;
        reason: string | null;
      };
      assert.ok(typeof outcome.error === "string" && outcome.error.length > 0, `${label}/${fault}: expected non-empty restored.json error`);
      assert.equal(outcome.reason, "error", `${label}/${fault}: expected reason === 'error'`);

      const db = new DatabaseSync(destDb, { readOnly: true });
      try {
        const sessCount = (db.prepare("SELECT COUNT(*) AS n FROM sessions").get() as { n: number }).n;
        assert.equal(sessCount, 0, `${label}/${fault}: target DB must have 0 sessions`);
        const hasMarkTable = db.prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'replica_restored'").get();
        if (hasMarkTable) {
          const markCount = (db.prepare("SELECT COUNT(*) AS n FROM replica_restored").get() as { n: number }).n;
          assert.equal(markCount, 0, `${label}/${fault}: target DB must have 0 replica_restored rows`);
        }
      } finally {
        db.close();
      }
    }
  }
});

test("--compact-heads dual-engine parity: identical root hash, compact IPC head, inline disk head.json, and non-compact omission (MB + Pion)", async (t) => {
  const bins = resolveDualBinaries(t);
  if (!bins) return;

  const made = makeTranscriptSeedStation();

  // 1. With --compact-heads: MB vs Pion must produce identical transcriptManifest root hash.
  const runCompact = async (label: string, bin: string) => {
    const rep = join(made.data, `replica-compact-${label}`);
    const exp = new ExportClient(bin, made.db, rep, made.data, ["--compact-heads", "--chunk-bytes", "1024"]);
    await exp.ask({ type: "places", places: PLACES });
    let p = await exp.ask({ type: "pass", told: nothingTold() });
    while (p.more) p = await exp.ask({ type: "pass", told: nothingTold() });
    const ipcHead = p.heads[HOME] as Record<string, any>;
    const diskHead = JSON.parse(readFileSync(join(rep, "own", HOME, String(ipcHead.gen), "head.json"), "utf8")) as Record<string, any>;
    await exp.close();
    return { rep, ipcHead, diskHead };
  };

  const mbC = await runCompact("mb", bins.mb);
  const pionC = await runCompact("pion", bins.pion);

  assert.equal(mbC.ipcHead.transcriptFiles, undefined, "MB compact IPC head must omit inline transcriptFiles");
  assert.equal(pionC.ipcHead.transcriptFiles, undefined, "Pion compact IPC head must omit inline transcriptFiles");
  assert.match(String(mbC.ipcHead.transcriptManifest), /^[0-9a-f]{64}$/);
  assert.equal(pionC.ipcHead.transcriptManifest, mbC.ipcHead.transcriptManifest, "Pion and MB transcriptManifest root hashes must match exactly");

  for (const [label, res] of [
    ["mb", mbC],
    ["pion", pionC],
  ] as const) {
    assert.equal(res.diskHead.transcriptManifest, undefined, `${label}: disk head.json must NOT carry transcriptManifest`);
    assert.ok(
      res.diskHead.transcriptFiles !== undefined && Object.keys(res.diskHead.transcriptFiles).length > 0,
      `${label}: disk head.json must retain inline transcriptFiles`,
    );
    const rootPath = join(res.rep, "manifests", String(res.ipcHead.transcriptManifest));
    assert.ok(existsSync(rootPath), `${label}: manifest root file must exist under <replica>/manifests/`);
    const rootParsed = JSON.parse(readFileSync(rootPath, "utf8")) as { v: number; buckets: Record<string, string> };
    assert.equal(rootParsed.v, 1);
    const leaves = Object.values(rootParsed.buckets);
    assert.ok(leaves.length > 0, `${label}: manifest root must reference >= 1 bucket leaf`);
    for (const lh of leaves) {
      const lp = join(res.rep, "manifests", lh);
      assert.ok(existsSync(lp), `${label}: manifest leaf ${lh} must exist under <replica>/manifests/`);
      const leafParsed = JSON.parse(readFileSync(lp, "utf8")) as { v: number; files: Record<string, number> };
      assert.equal(leafParsed.v, 1);
    }
  }
  assert.deepEqual(pionC.diskHead.transcriptFiles, mbC.diskHead.transcriptFiles, "disk head.json transcriptFiles must match between MB and Pion");

  // 2. Without --compact-heads: neither MB nor Pion emits transcriptManifest.
  for (const [label, bin] of [
    ["mb", bins.mb],
    ["pion", bins.pion],
  ] as const) {
    const rep = join(made.data, `replica-plain-${label}`);
    const exp = new ExportClient(bin, made.db, rep, made.data, ["--chunk-bytes", "1024"]);
    await exp.ask({ type: "places", places: PLACES });
    let p = await exp.ask({ type: "pass", told: nothingTold() });
    while (p.more) p = await exp.ask({ type: "pass", told: nothingTold() });
    const ipcHead = p.heads[HOME] as Record<string, any>;
    await exp.close();
    assert.equal(ipcHead.transcriptManifest, undefined, `${label}: without --compact-heads must NOT emit transcriptManifest`);
    assert.ok(
      ipcHead.transcriptFiles !== undefined && Object.keys(ipcHead.transcriptFiles).length > 0,
      `${label}: without --compact-heads must emit inline transcriptFiles`,
    );
  }
});

test("hot head_cache detects equal-size preserved-mtime head.json tampering (atomic replace & in-place) identically to cold restart (MB + Pion)", async (t) => {
  const bins = resolveDualBinaries(t);
  if (!bins) return;

  for (const [label, bin] of [
    ["mb", bins.mb],
    ["pion", bins.pion],
  ] as const) {
    for (const mode of ["atomic-replace", "in-place"] as const) {
      const made = station();
      cleanupDirs.push(made.data);
      const rep = join(made.data, `replica-hot-tamper-${mode}-${label}`);
      const exp = new ExportClient(bin, made.db, rep, made.data);
      await exp.ask({ type: "places", places: PLACES });
      const p1 = await exp.ask({ type: "pass", told: nothingTold() });
      assert.ok(p1.wrote >= 1);
      const gen = String(p1.heads[HOME].gen);
      const genDir = join(rep, "own", HOME, gen);
      const headPath = join(genDir, "head.json");
      const origStat = statSync(headPath);
      const origBytes = readFileSync(headPath);
      assert.ok(origBytes.length > 8);

      // Construct an equal-byte-length invalid JSON payload and preserve exact original mtime.
      const corruptBytes = Buffer.from("{INVALID" + " ".repeat(origBytes.length - 8), "utf8");
      assert.equal(corruptBytes.length, origBytes.length);
      if (mode === "atomic-replace") {
        const tmp = join(genDir, "head.json.tamper");
        writeFileSync(tmp, corruptBytes);
        utimesSync(tmp, origStat.atime, origStat.mtime);
        renameSync(tmp, headPath);
      } else {
        writeFileSync(headPath, corruptBytes);
        utimesSync(headPath, origStat.atime, origStat.mtime);
      }

      // Same hot process MUST immediately fail (never serve stale cache with wrote === 0).
      exp.now = NOW + 2000;
      await assert.rejects(
        () => exp.ask({ type: "pass", told: nothingTold() }),
        /corrupted/i,
        `${label}/${mode}: hot process must immediately reject equal-size preserved-mtime corrupted head.json`,
      );
      await exp.close();
    }
  }
});

test("dual-exporter A -> B -> A --compact-heads handover refreshes manifest_cache to B's latest root and restores byte-identically (MB->Pion->MB & Pion->MB->Pion)", async (t) => {
  const bins = resolveDualBinaries(t);
  if (!bins) return;

  for (const [labelA, binA, labelB, binB] of [
    ["mb", bins.mb, "pion", bins.pion],
    ["pion", bins.pion, "mb", bins.mb],
  ] as const) {
    const made = makeTranscriptSeedStation();
    const trFile = join(made.data, "homes", "p1", "agy", ".gemini", "antigravity-cli", "brain", "cid-manifest", "notes.md");
    const rep = join(made.data, `replica-aba-${labelA}-${labelB}`);

    // Exporter A stays alive after pass 1 (to=1) with warm head_cache + manifest_cache.
    const expA = new ExportClient(binA, made.db, rep, made.data, ["--compact-heads", "--chunk-bytes", "1024"]);
    await expA.ask({ type: "places", places: PLACES });
    let pA1 = await expA.ask({ type: "pass", told: nothingTold() });
    while (pA1.more) pA1 = await expA.ask({ type: "pass", told: nothingTold() });
    const headA1 = pA1.heads[HOME] as Record<string, any>;
    const rootA1 = String(headA1.transcriptManifest);
    assert.match(rootA1, /^[0-9a-f]{64}$/);
    const toA1 = Number(headA1.to);

    // Update the session's transcript file on disk, then Exporter B exports to=2 and closes.
    const updatedPayload = "updated-by-exporter-B-payload-".repeat(160);
    writeFileSync(trFile, updatedPayload);
    const future = new Date(NOW + 10_000);
    utimesSync(trFile, future, future);

    const expB = new ExportClient(binB, made.db, rep, made.data, ["--compact-heads", "--chunk-bytes", "1024"]);
    expB.now = NOW + 10_000;
    await expB.ask({ type: "places", places: PLACES });
    let pB = await expB.ask({ type: "pass", told: nothingTold() });
    while (pB.more) pB = await expB.ask({ type: "pass", told: nothingTold() });
    const headB = pB.heads[HOME] as Record<string, any>;
    const rootB = String(headB.transcriptManifest);
    const toB = Number(headB.to);
    assert.ok(toB > toA1, `${labelA}->${labelB}: B must advance to (${toB} > ${toA1})`);
    assert.notEqual(rootB, rootA1, `${labelA}->${labelB}: B must produce a new manifest root`);
    await expB.close();

    // Exporter A (still alive!) runs an idle pass: MUST detect updated head.json, invalidate manifest_cache,
    // and publish to=toB with B's latest transcriptManifest root!
    expA.now = NOW + 20_000;
    const pA2 = await expA.ask({ type: "pass", told: nothingTold() });
    const headA2 = pA2.heads[HOME] as Record<string, any>;
    assert.equal(Number(headA2.to), toB, `${labelA}->${labelB}->${labelA}: A must report B's latest to`);
    assert.equal(
      String(headA2.transcriptManifest),
      rootB,
      `${labelA}->${labelB}->${labelA}: A must publish B's latest transcriptManifest root (never stale ${rootA1})`,
    );

    // Next: mutate another session's title so A writes a new batch (to3 > toB) without re-scanning transcripts.
    // A MUST have invalidated tf_cache[ws] on head_cache miss so it writes B's latest transcriptFiles (never stale to=1)!
    const diskHeadB = JSON.parse(readFileSync(join(rep, "own", HOME, String(headB.gen), "head.json"), "utf8")) as Record<string, any>;
    const toldTitle = nothingTold();
    const unsubTitle = made.store.subscribe((c) => void tell(toldTitle, c));
    chat(made.store, made.data, "chat:title-bump", HOME, 1);
    made.store.setTitle("chat:title-bump", "bumped-after-aba");
    unsubTitle();

    expA.now = NOW + 22_000;
    const pA3 = await expA.ask({ type: "pass", told: toldTitle });
    const headA3 = pA3.heads[HOME] as Record<string, any>;
    const toA3 = Number(headA3.to);
    assert.ok(toA3 > toB, `${labelA}->${labelB}->${labelA}: A must advance to3 (${toA3} > ${toB}) after title edit`);
    assert.equal(
      String(headA3.transcriptManifest),
      rootB,
      `${labelA}->${labelB}->${labelA}: headA3.transcriptManifest must still equal B's latest root ${rootB}`,
    );
    const diskHeadA3 = JSON.parse(readFileSync(join(rep, "own", HOME, String(headA3.gen), "head.json"), "utf8")) as Record<string, any>;
    assert.deepEqual(
      diskHeadA3.transcriptFiles,
      diskHeadB.transcriptFiles,
      `${labelA}->${labelB}->${labelA}: disk head.json after to3 must retain B's transcriptFiles chunks`,
    );

    // Receiver copies ONLY the objects advertised by headA3 + manifest and restores.
    const manifestsDir = join(rep, "manifests");
    const rootObj = JSON.parse(readFileSync(join(manifestsDir, rootB), "utf8")) as { v: number; buckets: Record<string, string> };
    const leafHashes = Object.values(rootObj.buckets);
    const chunkHashes: string[] = [];
    for (const lh of leafHashes) {
      const leafObj = JSON.parse(readFileSync(join(manifestsDir, lh), "utf8")) as { v: number; files: Record<string, number> };
      chunkHashes.push(...Object.keys(leafObj.files));
    }
    const allHashes = [...Object.keys(headA3.files ?? {}), ...chunkHashes];
    const sources = (await expA.ask({ type: "sources", hashes: allHashes })) as Record<string, string>;
    await expA.close();

    const dest = tempDir(`w6b-aba-dest-${labelA}-${labelB}-`);
    const destDb = join(dest, "stillfail.db");
    Store.open(destDb).close();
    stageRestoreCopy(rep, made.data, HOME, String(headA3.gen), dest, sources);
    writeFileSync(join(dest, "restore", "copy", String(headA3.gen), "head.json"), JSON.stringify(headA3, null, 1));
    const copyFiles = join(dest, "restore", "copy", "files");
    cpSync(join(manifestsDir, rootB), join(copyFiles, rootB));
    for (const lh of leafHashes) {
      cpSync(join(manifestsDir, lh), join(copyFiles, lh));
    }

    await takeBackSoon(dest, destDb, NOW + 25_000, binA);
    const outcome = JSON.parse(readFileSync(join(dest, "replica", "restored.json"), "utf8")) as {
      error: string | null;
      missing: number;
      files: number;
    };
    assert.equal(outcome.error, null, `${labelA}->${labelB}->${labelA}: restore must succeed`);
    assert.equal(outcome.missing, 0, `${labelA}->${labelB}->${labelA}: restore must have 0 missing files`);
    assert.ok(outcome.files >= 1, `${labelA}->${labelB}->${labelA}: restore must place transcript files`);

    const restoredTr = join(dest, "homes", "p1", "agy", ".gemini", "antigravity-cli", "brain", "cid-manifest", "notes.md");
    assert.equal(
      readFileSync(restoredTr, "utf8"),
      updatedPayload,
      `${labelA}->${labelB}->${labelA}: restored transcript must match B's updated content byte-for-byte`,
    );
  }
});

function makeFourTranscriptStation(prefix: string) {
  const made = station();
  cleanupDirs.push(made.data);
  const trDir = join(made.data, "homes", "p1", "agy", ".gemini", "antigravity-cli", "brain", "cid-sweep4");
  mkdirSync(trDir, { recursive: true });
  const names = ["t1.md", "t2.md", "t3.md", "t4.md"] as const;
  const payloads: Record<string, string> = {};
  for (const name of names) {
    const body = `${prefix}-${name}-` + "z".repeat(1600);
    payloads[name] = body;
    writeFileSync(join(trDir, name), body);
  }
  made.store.db
    .prepare("INSERT INTO runtime_sessions (session_key, id, profile, at, runtime) VALUES (?, ?, ?, ?, ?)")
    .run("chat:a", "cid-sweep4", "p1", NOW, "agy");
  return { made, trDir, names, payloads };
}

test("dual-exporter cross-gen paginated transcript sweep handover (newGenerations) restores 4/4 files byte-identically (MB->Pion->MB & Pion->MB->Pion)", async (t) => {
  const bins = resolveDualBinaries(t);
  if (!bins) return;

  for (const [labelA, binA, labelB, binB] of [
    ["mb", bins.mb, "pion", bins.pion],
    ["pion", bins.pion, "mb", bins.mb],
  ] as const) {
    const { made, names, payloads } = makeFourTranscriptStation(`xgen-${labelA}-${labelB}`);
    const rep = join(made.data, `replica-xgen-sweep-${labelA}-${labelB}`);
    const flags = ["--compact-heads", "--chunk-bytes", "1024", "--transcript-pass-files", "1"];

    // Exporter A scans 3/4 files (leaving cursor at t4.md) and stays alive.
    const expA = new ExportClient(binA, made.db, rep, made.data, flags);
    await expA.ask({ type: "places", places: PLACES });
    for (let i = 0; i < 3; i++) {
      expA.now = NOW + i * 1000;
      const p = await expA.ask({ type: "pass", told: nothingTold() });
      assert.equal(p.more, true, `${labelA}: pass ${i + 1}/3 must have more=true`);
    }

    // Exporter B rotates to a new generation, writes only page 1 (more=true), and exits.
    const expB = new ExportClient(binB, made.db, rep, made.data, flags);
    expB.now = NOW + 10_000;
    await expB.ask({ type: "places", places: PLACES });
    await expB.ask({ type: "newGenerations", after: NOW + 10_000 });
    const pB1 = await expB.ask({ type: "pass", told: nothingTold() });
    assert.equal(pB1.more, true, `${labelB}: new-gen page 1 must have more=true`);
    const genB = String(pB1.heads[HOME].gen);
    await expB.close();

    // Exporter A resumes with empty told until more=false: MUST reset its old sweep cursor and finish all 4/4!
    let pA: any;
    let steps = 0;
    do {
      expA.now = NOW + 20_000 + steps * 1000;
      pA = await expA.ask({ type: "pass", told: nothingTold() });
      steps++;
      assert.ok(steps <= 12, `${labelA}->${labelB}->${labelA}: sweep must converge within 12 passes`);
    } while (pA.more);

    const finalHead = pA.heads[HOME] as Record<string, any>;
    assert.equal(String(finalHead.gen), genB, `${labelA}->${labelB}->${labelA}: A must stay on B's new generation`);
    const rootHash = String(finalHead.transcriptManifest);
    const manifestsDir = join(rep, "manifests");
    const rootObj = JSON.parse(readFileSync(join(manifestsDir, rootHash), "utf8")) as { v: number; buckets: Record<string, string> };
    const leafHashes = Object.values(rootObj.buckets);
    const chunkHashes: string[] = [];
    for (const lh of leafHashes) {
      const leafObj = JSON.parse(readFileSync(join(manifestsDir, lh), "utf8")) as { v: number; files: Record<string, number> };
      chunkHashes.push(...Object.keys(leafObj.files));
    }
    const sources = (await expA.ask({ type: "sources", hashes: [...Object.keys(finalHead.files ?? {}), ...chunkHashes] })) as Record<string, string>;
    await expA.close();

    const dest = tempDir(`w6b-xgen-sweep-dest-${labelA}-${labelB}-`);
    const destDb = join(dest, "stillfail.db");
    Store.open(destDb).close();
    stageRestoreCopy(rep, made.data, HOME, genB, dest, sources);
    writeFileSync(join(dest, "restore", "copy", genB, "head.json"), JSON.stringify(finalHead, null, 1));
    const copyFiles = join(dest, "restore", "copy", "files");
    cpSync(join(manifestsDir, rootHash), join(copyFiles, rootHash));
    for (const lh of leafHashes) cpSync(join(manifestsDir, lh), join(copyFiles, lh));

    await takeBackSoon(dest, destDb, NOW + 40_000, binA);
    const outcome = JSON.parse(readFileSync(join(dest, "replica", "restored.json"), "utf8")) as {
      error: string | null;
      missing: number;
      files: number;
    };
    assert.equal(outcome.error, null, `${labelA}->${labelB}->${labelA}: cross-gen restore error`);
    assert.equal(outcome.missing, 0, `${labelA}->${labelB}->${labelA}: cross-gen restore missing`);
    assert.equal(
      outcome.files,
      Object.keys(finalHead.files ?? {}).length + names.length,
      `${labelA}->${labelB}->${labelA}: cross-gen restore must place all carried + 4/4 transcript files`,
    );
    for (const name of names) {
      const got = readFileSync(join(dest, "homes", "p1", "agy", ".gemini", "antigravity-cli", "brain", "cid-sweep4", name), "utf8");
      assert.equal(got, payloads[name], `${labelA}->${labelB}->${labelA}: ${name} byte-identical`);
    }
  }
});

test("dual-exporter same-gen paginated transcript sweep handover restores all 4/4 updated files byte-identically (MB->Pion->MB & Pion->MB->Pion)", async (t) => {
  const bins = resolveDualBinaries(t);
  if (!bins) return;

  for (const [labelA, binA, labelB, binB] of [
    ["mb", bins.mb, "pion", bins.pion],
    ["pion", bins.pion, "mb", bins.mb],
  ] as const) {
    const { made, trDir, names } = makeFourTranscriptStation(`sgen-v1-${labelA}-${labelB}`);
    const rep = join(made.data, `replica-sgen-sweep-${labelA}-${labelB}`);
    const flags = ["--compact-heads", "--chunk-bytes", "1024", "--transcript-pass-files", "1"];

    // Exporter A completes full 4/4 sweep (more=false) and stays alive.
    const expA = new ExportClient(binA, made.db, rep, made.data, flags);
    await expA.ask({ type: "places", places: PLACES });
    let pA: any;
    let initSteps = 0;
    do {
      expA.now = NOW + initSteps * 1000;
      pA = await expA.ask({ type: "pass", told: nothingTold() });
      initSteps++;
    } while (pA.more);
    const gen = String(pA.heads[HOME].gen);

    // Update ALL 4 transcript files on disk, then Exporter B exports only page 1 (more=true) and exits.
    const v2Payloads: Record<string, string> = {};
    const v2Time = new Date(NOW + 15_000);
    for (const name of names) {
      const body = `sgen-v2-${labelA}-${labelB}-${name}-` + "q".repeat(1800);
      v2Payloads[name] = body;
      const fp = join(trDir, name);
      writeFileSync(fp, body);
      utimesSync(fp, v2Time, v2Time);
    }

    const expB = new ExportClient(binB, made.db, rep, made.data, flags);
    expB.now = NOW + 15_000;
    await expB.ask({ type: "places", places: PLACES });
    const pB1 = await expB.ask({ type: "pass", told: nothingTold() });
    assert.equal(pB1.more, true, `${labelB}: same-gen page 1 must have more=true`);
    assert.equal(String(pB1.heads[HOME].gen), gen, `${labelB}: must stay on same gen`);
    await expB.close();

    // Exporter A resumes with empty told until more=false: MUST detect B's advancement and export remaining 3/4!
    let steps = 0;
    do {
      expA.now = NOW + 25_000 + steps * 1000;
      pA = await expA.ask({ type: "pass", told: nothingTold() });
      steps++;
      assert.ok(steps <= 12, `${labelA}->${labelB}->${labelA}: same-gen sweep must converge within 12 passes`);
    } while (pA.more);

    const finalHead = pA.heads[HOME] as Record<string, any>;
    const rootHash = String(finalHead.transcriptManifest);
    const manifestsDir = join(rep, "manifests");
    const rootObj = JSON.parse(readFileSync(join(manifestsDir, rootHash), "utf8")) as { v: number; buckets: Record<string, string> };
    const leafHashes = Object.values(rootObj.buckets);
    const chunkHashes: string[] = [];
    for (const lh of leafHashes) {
      const leafObj = JSON.parse(readFileSync(join(manifestsDir, lh), "utf8")) as { v: number; files: Record<string, number> };
      chunkHashes.push(...Object.keys(leafObj.files));
    }
    const sources = (await expA.ask({ type: "sources", hashes: [...Object.keys(finalHead.files ?? {}), ...chunkHashes] })) as Record<string, string>;
    await expA.close();

    const dest = tempDir(`w6b-sgen-sweep-dest-${labelA}-${labelB}-`);
    const destDb = join(dest, "stillfail.db");
    Store.open(destDb).close();
    stageRestoreCopy(rep, made.data, HOME, gen, dest, sources);
    writeFileSync(join(dest, "restore", "copy", gen, "head.json"), JSON.stringify(finalHead, null, 1));
    const copyFiles = join(dest, "restore", "copy", "files");
    cpSync(join(manifestsDir, rootHash), join(copyFiles, rootHash));
    for (const lh of leafHashes) cpSync(join(manifestsDir, lh), join(copyFiles, lh));

    await takeBackSoon(dest, destDb, NOW + 45_000, binA);
    const outcome = JSON.parse(readFileSync(join(dest, "replica", "restored.json"), "utf8")) as {
      error: string | null;
      missing: number;
      files: number;
    };
    assert.equal(outcome.error, null, `${labelA}->${labelB}->${labelA}: same-gen restore error`);
    assert.equal(outcome.missing, 0, `${labelA}->${labelB}->${labelA}: same-gen restore missing`);
    assert.equal(
      outcome.files,
      Object.keys(finalHead.files ?? {}).length + names.length,
      `${labelA}->${labelB}->${labelA}: same-gen restore must place all carried + 4/4 transcript files`,
    );
    for (const name of names) {
      const got = readFileSync(join(dest, "homes", "p1", "agy", ".gemini", "antigravity-cli", "brain", "cid-sweep4", name), "utf8");
      assert.equal(got, v2Payloads[name], `${labelA}->${labelB}->${labelA}: ${name} updated content byte-identical`);
    }
  }
});

test("dual-exporter multi-workspace (w, z) paginated sweep handover resets z cursor when B only advances w (MB->Pion->MB & Pion->MB->Pion)", async (t) => {
  const bins = resolveDualBinaries(t);
  if (!bins) return;

  for (const [labelA, binA, labelB, binB] of [
    ["mb", bins.mb, "pion", bins.pion],
    ["pion", bins.pion, "mb", bins.mb],
  ] as const) {
    const made = station();
    cleanupDirs.push(made.data);
    const wDir = join(made.data, "homes", "p1", "agy", ".gemini", "antigravity-cli", "brain", "cid-mw-w");
    const zDir = join(made.data, "homes", "p1", "agy", ".gemini", "antigravity-cli", "brain", "cid-mw-z");
    mkdirSync(wDir, { recursive: true });
    mkdirSync(zDir, { recursive: true });

    const wFile = join(wDir, "w1.md");
    const zNames = ["z1.md", "z2.md", "z3.md"] as const;
    writeFileSync(wFile, `mw-v1-w-${labelA}-${labelB}-` + "a".repeat(1600));
    for (const name of zNames) {
      writeFileSync(join(zDir, name), `mw-v1-z-${labelA}-${labelB}-${name}-` + "b".repeat(1600));
    }
    made.store.db
      .prepare("INSERT INTO runtime_sessions (session_key, id, profile, at, runtime) VALUES (?, ?, ?, ?, ?)")
      .run("chat:a", "cid-mw-w", "p1", NOW, "agy");
    made.store.db
      .prepare("INSERT INTO runtime_sessions (session_key, id, profile, at, runtime) VALUES (?, ?, ?, ?, ?)")
      .run("chat:o", "cid-mw-z", "p1", NOW, "agy");

    const rep = join(made.data, `replica-mw-sweep-${labelA}-${labelB}`);
    const flags = ["--compact-heads", "--chunk-bytes", "1024", "--transcript-pass-files", "1"];

    // 1. Exporter A scans w (1/1) + z (2/3), stopping mid-sweep on z with cursor past z1/z2, and stays alive.
    const expA = new ExportClient(binA, made.db, rep, made.data, flags);
    await expA.ask({ type: "places", places: PLACES });
    let pA: any;
    for (let i = 0; i < 3; i++) {
      expA.now = NOW + i * 1000;
      pA = await expA.ask({ type: "pass", told: nothingTold() });
      assert.equal(pA.more, true, `${labelA}: pass ${i + 1}/3 must have more=true`);
    }
    const prevWTo = Number(pA.heads[HOME].to);
    const prevZTo = Number(pA.heads[OTHER].to);

    // 2. Update ALL files in both w and z on disk; Exporter B runs 1 pass with budget 1 (advances only w, leaves z untouched) and exits.
    const v2Time = new Date(NOW + 15_000);
    writeFileSync(wFile, `mw-v2-w-${labelA}-${labelB}-` + "c".repeat(1800));
    utimesSync(wFile, v2Time, v2Time);
    const zV2Payloads: Record<string, string> = {};
    for (const name of zNames) {
      const body = `mw-v2-z-${labelA}-${labelB}-${name}-` + "d".repeat(1800);
      zV2Payloads[name] = body;
      const fp = join(zDir, name);
      writeFileSync(fp, body);
      utimesSync(fp, v2Time, v2Time);
    }

    const expB = new ExportClient(binB, made.db, rep, made.data, flags);
    expB.now = NOW + 15_000;
    await expB.ask({ type: "places", places: PLACES });
    const pB1 = await expB.ask({ type: "pass", told: nothingTold() });
    assert.equal(pB1.more, true, `${labelB}: multi-ws page 1 must have more=true`);
    assert.ok(Number(pB1.heads[HOME].to) > prevWTo, `${labelB}: must advance w head.to`);
    assert.equal(Number(pB1.heads[OTHER].to), prevZTo, `${labelB}: must leave z head.to untouched`);
    await expB.close();

    // 3. Exporter A resumes with empty told until more=false: seeing w advance MUST forget_sweep() so z is fully re-scanned!
    let steps = 0;
    do {
      expA.now = NOW + 25_000 + steps * 1000;
      pA = await expA.ask({ type: "pass", told: nothingTold() });
      steps++;
      assert.ok(steps <= 12, `${labelA}->${labelB}->${labelA}: multi-ws sweep must converge within 12 passes`);
    } while (pA.more);

    const finalZHead = pA.heads[OTHER] as Record<string, any>;
    const genZ = String(finalZHead.gen);
    const rootHash = String(finalZHead.transcriptManifest);
    const manifestsDir = join(rep, "manifests");
    const rootObj = JSON.parse(readFileSync(join(manifestsDir, rootHash), "utf8")) as { v: number; buckets: Record<string, string> };
    const leafHashes = Object.values(rootObj.buckets);
    const chunkHashes: string[] = [];
    for (const lh of leafHashes) {
      const leafObj = JSON.parse(readFileSync(join(manifestsDir, lh), "utf8")) as { v: number; files: Record<string, number> };
      chunkHashes.push(...Object.keys(leafObj.files));
    }
    const sources = (await expA.ask({ type: "sources", hashes: [...Object.keys(finalZHead.files ?? {}), ...chunkHashes] })) as Record<string, string>;
    await expA.close();

    // 4. Restore z from A's final z head and assert all 3/3 updated z files are byte-identical (files=3, missing=0, error=null).
    const dest = tempDir(`w6b-mw-sweep-dest-${labelA}-${labelB}-`);
    const destDb = join(dest, "stillfail.db");
    Store.open(destDb).close();
    stageRestoreCopy(rep, made.data, OTHER, genZ, dest, sources);
    writeFileSync(join(dest, "restore", "copy", genZ, "head.json"), JSON.stringify(finalZHead, null, 1));
    const copyFiles = join(dest, "restore", "copy", "files");
    cpSync(join(manifestsDir, rootHash), join(copyFiles, rootHash));
    for (const lh of leafHashes) cpSync(join(manifestsDir, lh), join(copyFiles, lh));

    await takeBackSoon(dest, destDb, NOW + 45_000, binA);
    const outcome = JSON.parse(readFileSync(join(dest, "replica", "restored.json"), "utf8")) as {
      error: string | null;
      missing: number;
      files: number;
    };
    assert.equal(outcome.error, null, `${labelA}->${labelB}->${labelA}: multi-ws z restore error`);
    assert.equal(outcome.missing, 0, `${labelA}->${labelB}->${labelA}: multi-ws z restore missing`);
    assert.equal(outcome.files, 3, `${labelA}->${labelB}->${labelA}: multi-ws z restore must place all 3/3 files`);
    for (const name of zNames) {
      const got = readFileSync(join(dest, "homes", "p1", "agy", ".gemini", "antigravity-cli", "brain", "cid-mw-z", name), "utf8");
      assert.equal(got, zV2Payloads[name], `${labelA}->${labelB}->${labelA}: z/${name} updated content byte-identical`);
    }
  }
});
