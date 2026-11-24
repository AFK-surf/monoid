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
import { HOME, ORIGIN, OTHER, attach, chat, station } from "./replica-fakes.ts";

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

  for (const tbl of [
    "threads",
    "sessions",
    "thread_sessions",
    "entries",
    "letters",
    "runtime_sessions",
    "turns",
    "reads",
    "pins",
    "closed_cards",
    "opened_chats",
    "replica_restored",
  ]) {
    const rowsA = dumpTableRows(dbA, tbl).map((r) => JSON.stringify(r).replaceAll(destA, "<DATA>").replaceAll(headMb.gen, "<GEN>"));
    const rowsB = dumpTableRows(dbB, tbl).map((r) => JSON.stringify(r).replaceAll(destB, "<DATA>").replaceAll(headPion.gen, "<GEN>"));
    assert.deepEqual(rowsA, rowsB, `table ${tbl} must match 0-diff between MB->Pion and Pion->MB`);
  }

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
  const headPath = join(rep, "own", HOME, gen, "head.json");
  const savedHead = readFileSync(headPath, "utf8");

  // Add a new entry and replace head.json with a directory so writing head.json fails!
  const told = nothingTold();
  made.store.subscribe((c) => void tell(told, c));
  const th = made.store.db.prepare("SELECT id FROM threads ORDER BY id LIMIT 1").get() as { id: number };
  made.store.insertMessage({ thread: th.id, ts: "r2.fault", authorKind: "person", author: "p@x", text: "after-head-fault" });
  rmSync(headPath);
  mkdirSync(headPath);

  await assert.rejects(() => exp.ask({ type: "pass", told }), /EISDIR|Is a directory/i);

  // Restore head.json and retry pass: because export.db rolled back, the new entry is still exported cleanly.
  rmSync(headPath, { recursive: true });
  writeFileSync(headPath, savedHead);
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
    // Run pass 1, capture gen, then start a brand-new cold process where head.json is replaced by a directory on its FIRST pass.
    const seed = new ExportClient(bin, m2.db, rep2, m2.data);
    await seed.ask({ type: "places", places: PLACES });
    const sp1 = await seed.ask({ type: "pass", told: nothingTold() });
    const g2 = sp1.heads[HOME].gen as string;
    const h2Path = join(rep2, "own", HOME, g2, "head.json");
    const h2Saved = readFileSync(h2Path, "utf8");
    const logDir2 = join(rep2, "own", HOME, g2, "log");
    await seed.close();

    // Modify source DB while cold exporter is stopped, then block head.json with a directory.
    const th2 = m2.store.db.prepare("SELECT id FROM threads ORDER BY id LIMIT 1").get() as { id: number };
    m2.store.insertMessage({ thread: th2.id, ts: "r2.coldfault", authorKind: "person", author: "p@x", text: `cold-fault-msg-${label}` });
    rmSync(h2Path);
    mkdirSync(h2Path);

    const cold = new ExportClient(bin, m2.db, rep2, m2.data);
    cold.now = NOW + 2000;
    await cold.ask({ type: "places", places: PLACES });
    await assert.rejects(() => cold.ask({ type: "pass", told: nothingTold() }), /EISDIR|Is a directory/i);

    // Fix head.json path and retry IN THE SAME PROCESS (without restarting): must write the rolled-back change!
    rmSync(h2Path, { recursive: true });
    writeFileSync(h2Path, h2Saved);
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
    const entries2 = dumpTableRows(destDb2, "entries");
    assert.ok(
      entries2.some((e) => JSON.stringify(e).includes(`cold-fault-msg-${label}`)),
      `${label}: restored DB must include message exported on same-process retry`,
    );
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

test("corrupted head.json on existing generation aborts pass and preserves all historical batches (MB + Pion)", async (t) => {
  const bins = resolveDualBinaries(t);
  if (!bins) return;

  for (const [label, bin] of [
    ["mb", bins.mb],
    ["pion", bins.pion],
  ] as const) {
    const made = station();
    cleanupDirs.push(made.data);
    // Ensure two distinct sessions exist (`chat:a` unchanged, `chat:b` updated later).
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
    const savedHead = readFileSync(headPath, "utf8");
    const savedBatches = readdirSync(logDir).sort();
    assert.ok(savedBatches.length >= 1);

    // Corrupt head.json, update second session/message, and run pass -> MUST fail & keep all historical batches!
    writeFileSync(headPath, "{corrupted-json");
    made.store.insertMessage({ thread: thA.id, ts: "x.2", authorKind: "person", author: "p@x", text: "updated-after-corrupt" });
    await assert.rejects(() => exp.ask({ type: "pass", told: nothingTold() }), /corrupt|json|head/i);
    assert.deepEqual(
      readdirSync(logDir).sort(),
      savedBatches,
      `${label}: historical batches must NEVER be deleted when head.json is corrupted`,
    );

    // Restore valid head.json -> next pass succeeds and full restore retains BOTH unchanged and updated messages!
    writeFileSync(headPath, savedHead);
    const p2 = await exp.ask({ type: "pass", told: nothingTold() });
    assert.ok(p2.wrote >= 1);
    const hashes = [...Object.keys(p2.heads[HOME].files ?? {}), ...Object.keys(p2.heads[HOME].transcriptFiles ?? {})];
    const sources = await exp.ask({ type: "sources", hashes });
    await exp.close();

    const dest = tempDir(`w6b-corrupt-dest-${label}-`);
    const destDb = join(dest, "stillfail.db");
    Store.open(destDb).close();
    stageRestoreCopy(rep, made.data, HOME, gen, dest, sources);
    await takeBackSoon(dest, destDb, NOW + 4000, bin);
    const restoredSessions = dumpTableRows(destDb, "sessions");
    assert.ok(restoredSessions.length >= 2, `${label}: both sessions must survive after head.json corruption recovery`);
    const restoredEntries = dumpTableRows(destDb, "entries");
    assert.ok(restoredEntries.some((e) => JSON.stringify(e).includes("unchanged-session-msg")), `${label}: unchanged message preserved`);
    assert.ok(restoredEntries.some((e) => JSON.stringify(e).includes("updated-after-corrupt")), `${label}: updated message preserved`);
  }
});

test("CLI numeric flag parity: --batch-bytes 4294967296 falls back to default and --now +1 parses as 1 (MB + Pion)", async (t) => {
  const bins = resolveDualBinaries(t);
  if (!bins) return;

  for (const [label, bin] of [
    ["mb", bins.mb],
    ["pion", bins.pion],
  ] as const) {
    const made = station();
    cleanupDirs.push(made.data);
    const rep = join(made.data, `replica-cli-num-${label}`);
    const p = new MbProcess(bin, [
      "--builder",
      "replica-export",
      "--db",
      made.db,
      "--replica",
      rep,
      "--data-dir",
      made.data,
      "--origin",
      ORIGIN,
      "--sep",
      sep,
      "--batch-bytes",
      "4294967296",
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
      assert.ok(passed.wrote >= 1, `${label}: --batch-bytes 4294967296 must fall back to default, not 0`);
      const head = passed.heads[HOME];
      const hashes = [...Object.keys(head.files ?? {}), ...Object.keys(head.transcriptFiles ?? {})];
      const sources = await ask({ type: "sources", hashes });
      await ask({ type: "close" });

      // Test --now +1 on replica-restore
      const dest = tempDir(`w6b-now-plus1-${label}-`);
      const destDb = join(dest, "stillfail.db");
      Store.open(destDb).close();
      stageRestoreCopy(rep, made.data, HOME, head.gen, dest, sources);
      const rp = new MbProcess(bin, ["--builder", "replica-restore", "--db", destDb, "--data", dest, "--now", "+1", "--sep", sep]);
      const rmsg = await new Promise<{ ready?: unknown; error?: string }>((resolve, reject) => {
        rp.once("message", resolve);
        rp.once("error", reject);
      });
      assert.equal(rmsg.error, undefined);
      const outcome = JSON.parse(readFileSync(join(dest, "replica", "restored.json"), "utf8"));
      assert.equal(outcome.at, 1, `${label}: --now +1 must parse as 1`);
    } finally {
      p.kill();
    }
  }
});
