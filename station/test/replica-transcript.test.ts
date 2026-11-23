// Tests for Phase 2 session transcript 4 MiB chunked CAS incremental backup, GC, `carriedTo` path remapping on
// restore, `includeTranscripts: false` S3 policy, and workspace exclusion (both TS reference and MoonBit reader).
import assert from "node:assert/strict";
import { createHash, createHmac } from "node:crypto";
import { EventEmitter } from "node:events";
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, utimesSync, writeFileSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { join, sep } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { afterEach, test } from "node:test";
import { Effect, Exit, Scope, type Clock } from "effect";
import { TestClock } from "effect/testing";
import { PeerBus, bytesOf, withBytes } from "../src/mesh/bus.ts";
import { Fibers } from "../src/ops/fibers.ts";
import { MbProcess, mbReaderBinary } from "../src/read/mb-reader.ts";
import { claudeProject } from "../src/read/transcript.ts";
import type { NormalizedBackupConfig, NormalizedS3Target } from "../src/replica/backup-config.ts";
import { Copies } from "../src/replica/copies.ts";
import { PeerPlace, serve } from "../src/replica/peers.ts";
import { FolderPlace, level } from "../src/replica/places.ts";
import { moved, takeBackSoon } from "../src/replica/restore.ts";
import { ProgramRunner, exportThread } from "../src/replica/runner.ts";
import { S3Place } from "../src/replica/s3.ts";
import { Store } from "../src/store/store.ts";
import { HOME, dataDir } from "./replica-fakes.ts";
import { CHUNK_GC_GRACE_MS, Exporter, nothingTold } from "./reference/replica-export.ts";
import { decodeBatch } from "./reference/replica-format.ts";
import { takeBack } from "./reference/replica-restore.ts";
import { InlineRunner } from "./reference/replica-work.ts";

const binary = mbReaderBinary();
const skipMb = binary === null ? "the MoonBit program is not built here (station/mb/build.sh)" : false;

const scopes: Scope.Closeable[] = [];
const closing: (() => Promise<void>)[] = [];

afterEach(async () => {
  for (const c of closing.splice(0).reverse()) await c().catch(() => {});
  for (const s of scopes.splice(0)) await Effect.runPromise(Scope.close(s, Exit.void));
});

function testClock(): Clock.Clock & { move: (ms: number) => Promise<void> } {
  const scope = Effect.runSync(Scope.make());
  scopes.push(scope);
  const clock = Effect.runSync(Scope.provide(TestClock.make(), scope));
  return Object.assign(clock, { move: (ms: number) => Effect.runPromise(clock.adjust(`${ms} millis`)) });
}

const sid = (c: string) => c.repeat(64);
const TEST_KEY = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

function escapeXml(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&apos;");
}

class MockS3Server {
  readonly objects = new Map<string, Buffer>();
  readonly puts: string[] = [];
  readonly deletes: string[] = [];
  readonly bucket = "transcript-bucket";
  readonly region = "auto";
  readonly accessKeyId = "AKIA_TR_TEST";
  readonly secretAccessKey = "SECRET_TR_TEST";
  #server = createServer((req, res) => void this.#handle(req, res));
  endpoint = "";

  async start(): Promise<void> {
    await new Promise<void>((resolve) => {
      this.#server.listen(0, "127.0.0.1", () => {
        const addr = this.#server.address();
        assert.ok(addr !== null && typeof addr === "object");
        this.endpoint = `http://127.0.0.1:${addr.port}`;
        resolve();
      });
    });
    closing.push(() => new Promise<void>((resolve) => this.#server.close(() => resolve())));
  }

  target(overrides: Partial<NormalizedS3Target> = {}): NormalizedS3Target {
    return {
      id: "r2tr",
      name: "R2 Transcripts",
      endpoint: this.endpoint,
      region: this.region,
      bucket: this.bucket,
      prefix: "stillfail-backup",
      forcePathStyle: true,
      accessKeyId: this.accessKeyId,
      secretAccessKey: this.secretAccessKey,
      encryptionKey: TEST_KEY,
      includeTranscripts: true,
      ...overrides,
    };
  }

  async #readBody(req: IncomingMessage): Promise<Buffer> {
    const chunks: Buffer[] = [];
    for await (const c of req) chunks.push(Buffer.isBuffer(c) ? c : Buffer.from(c));
    return Buffer.concat(chunks);
  }

  async #handle(req: IncomingMessage, res: ServerResponse): Promise<void> {
    const url = new URL(req.url ?? "/", this.endpoint);
    const body = await this.#readBody(req);
    const segments = url.pathname.replace(/^\/+/, "").split("/").map(decodeURIComponent);
    const bucket = segments[0] ?? "";
    const key = segments.slice(1).join("/");
    if (bucket !== this.bucket) {
      res.writeHead(404).end("<Error><Code>NoSuchBucket</Code></Error>");
      return;
    }
    if (req.method === "GET" && url.searchParams.get("list-type") === "2") {
      const prefix = url.searchParams.get("prefix") ?? "";
      const matching = [...this.objects.keys()].filter((k) => k.startsWith(prefix)).sort();
      const xml =
        `<?xml version="1.0" encoding="UTF-8"?><ListBucketResult><IsTruncated>false</IsTruncated>` +
        matching.map((k) => `<Contents><Key>${escapeXml(k)}</Key><Size>${this.objects.get(k)!.length}</Size></Contents>`).join("") +
        `</ListBucketResult>`;
      res.writeHead(200, { "content-type": "application/xml" }).end(xml);
      return;
    }
    if (req.method === "PUT") {
      this.objects.set(key, body);
      this.puts.push(key);
      const etag = `"${createHash("md5").update(body).digest("hex")}"`;
      res.writeHead(200, { etag }).end();
      return;
    }
    if (req.method === "GET") {
      const obj = this.objects.get(key);
      if (obj === undefined) {
        res.writeHead(404).end("<Error><Code>NoSuchKey</Code></Error>");
        return;
      }
      res.writeHead(200, { "content-type": "application/octet-stream" }).end(obj);
      return;
    }
    if (req.method === "DELETE") {
      this.objects.delete(key);
      this.deletes.push(key);
      res.writeHead(204).end();
      return;
    }
    res.writeHead(405).end();
  }
}

function makeTranscriptStation() {
  const data = dataDir("tr-src");
  const db = join(data, "stillfail.db");
  const store = Store.open(db, join(data, "archive"));

  // 1. Claude session with transcript + subagent transcript + workspace code (must NOT be backed up)
  const claudeRoom = join(data, "sessions", "chat", "chat:claude", "workspace");
  mkdirSync(join(claudeRoom, "src"), { recursive: true });
  const workspaceSecret = join(claudeRoom, "src", "secret.ts");
  writeFileSync(workspaceSecret, "export const DO_NOT_BACKUP = true;\n");
  const claudeId = "claude-sess-001";
  store.insertSession({
    key: "chat:claude",
    connect: "chat",
    runtime: "claude",
    profile: "cc",
    workspace: claudeRoom,
    token: "tok-claude",
    createdAt: 1,
    lastActiveAt: 1,
    ws: null,
  });
  store.setRuntimeSessionId("chat:claude", claudeId);
  const tClaude = store.openThread("chat", "C", "ts-claude", "Claude Chat", "p@x").id;
  store.joinThread(tClaude, "chat:claude", "chat");
  // Chat attachment (MUST be backed up even when includeTranscripts: false)
  const attDir = join(claudeRoom, "uploads");
  mkdirSync(attDir, { recursive: true });
  const attPath = join(attDir, "note.txt");
  writeFileSync(attPath, "attached note content");
  store.insertMessage({
    thread: tClaude,
    ts: "c.1",
    authorKind: "person",
    author: "p@x",
    text: "hello claude",
    attachments: [{ name: "note.txt", path: attPath, size: 21 }],
  });

  const claudeProj = claudeProject(claudeRoom)!;
  const claudeTrDir = join(data, "transcripts", "claude", claudeProj);
  mkdirSync(join(claudeTrDir, claudeId), { recursive: true });
  const claudeTrPath = join(claudeTrDir, `${claudeId}.jsonl`);
  // Make ~10 KiB (> 2 chunks of 4 KiB) with deterministic content
  const lineA = JSON.stringify({ role: "user", text: "A".repeat(2000) }) + "\n";
  const lineB = JSON.stringify({ role: "assistant", text: "B".repeat(2000) }) + "\n";
  const lineC = JSON.stringify({ role: "user", text: "C".repeat(2000) }) + "\n";
  const lineD = JSON.stringify({ role: "assistant", text: "D".repeat(2000) }) + "\n";
  const lineE = JSON.stringify({ role: "user", text: "E".repeat(2000) }) + "\n";
  const claudeInitial = lineA + lineB + lineC + lineD + lineE;
  writeFileSync(claudeTrPath, claudeInitial);
  utimesSync(claudeTrPath, new Date(1_700_000_000_000), new Date(1_700_000_000_000));
  const claudeSubPath = join(claudeTrDir, claudeId, "sub-1.jsonl");
  writeFileSync(claudeSubPath, '{"sub":true}\n');

  // 2. Codex session with rollout transcript
  const codexRoom = join(data, "sessions", "chat", "chat:codex", "workspace");
  mkdirSync(codexRoom, { recursive: true });
  const codexId = "codex-sess-002";
  store.insertSession({
    key: "chat:codex",
    connect: "chat",
    runtime: "codex",
    profile: "cx",
    workspace: codexRoom,
    token: "tok-codex",
    createdAt: 2,
    lastActiveAt: 2,
    ws: null,
  });
  store.setRuntimeSessionId("chat:codex", codexId);
  const tCodex = store.openThread("chat", "C", "ts-codex", "Codex Chat", "p@x").id;
  store.joinThread(tCodex, "chat:codex", "chat");
  store.insertMessage({ thread: tCodex, ts: "x.1", authorKind: "person", author: "p@x", text: "hello codex" });
  const codexTrDir = join(data, "transcripts", "codex", "2026", "11", "22");
  mkdirSync(codexTrDir, { recursive: true });
  const codexTrPath = join(codexTrDir, `rollout-2026-11-22-${codexId}.jsonl`);
  const codexContent = '{"type":"event","payload":"codex-rollout-body"}\n';
  writeFileSync(codexTrPath, codexContent);

  // 3. AGY session with conversations/*.db, annotations/*.pbtxt, brain/<id>/**
  const agyRoom = join(data, "sessions", "chat", "chat:agy", "workspace");
  mkdirSync(agyRoom, { recursive: true });
  const agyId = "agy-sess-003";
  store.insertSession({
    key: "chat:agy",
    connect: "chat",
    runtime: "agy",
    profile: "agyprof",
    workspace: agyRoom,
    token: "tok-agy",
    createdAt: 3,
    lastActiveAt: 3,
    ws: null,
  });
  store.setRuntimeSessionId("chat:agy", agyId);
  const tAgy = store.openThread("chat", "C", "ts-agy", "AGY Chat", "p@x").id;
  store.joinThread(tAgy, "chat:agy", "chat");
  store.insertMessage({ thread: tAgy, ts: "g.1", authorKind: "person", author: "p@x", text: "hello agy" });
  const agyCli = join(data, "homes", "agyprof", "agy", ".gemini", "antigravity-cli");
  mkdirSync(join(agyCli, "conversations"), { recursive: true });
  mkdirSync(join(agyCli, "annotations"), { recursive: true });
  mkdirSync(join(agyCli, "brain", agyId, "notes"), { recursive: true });
  const agyDbPath = join(agyCli, "conversations", `${agyId}.db`);
  const agyAnnPath = join(agyCli, "annotations", `${agyId}.pbtxt`);
  const agyBrainPath = join(agyCli, "brain", agyId, "notes", "plan.md");
  const agyDbBytes = Buffer.from([0x53, 0x51, 0x4c, 0x69, 0x74, 0x65, 0x00, 0xde, 0xad, 0xbe, 0xef]);
  writeFileSync(agyDbPath, agyDbBytes);
  writeFileSync(agyAnnPath, 'status: "active"\n');
  writeFileSync(agyBrainPath, "# Plan\n- Step 1\n");
  // Also place a fake token file under homes/agyprof/ (outside antigravity-cli whitelist): must NOT be backed up!
  const agyTokenPath = join(data, "homes", "agyprof", "auth-token.json");
  writeFileSync(agyTokenPath, '{"token":"super-secret"}');

  return {
    data,
    db,
    store,
    claudeRoom,
    claudeId,
    claudeTrPath,
    claudeSubPath,
    claudeInitial,
    workspaceSecret,
    codexTrPath,
    codexContent,
    agyDbPath,
    agyDbBytes,
    agyAnnPath,
    agyBrainPath,
    agyTokenPath,
  };
}

test("TS reference: transcript discovery whitelist, 4 KiB chunk dedup, and orphan chunk GC", () => {
  const s = makeTranscriptStation();
  closing.push(async () => s.store.close());
  const replica = join(s.data, "replica");
  let now = 1_700_000_000_000;
  const exporter = new Exporter({
    db: s.db,
    replica,
    dataDir: s.data,
    origin: sid("a"),
    now: () => now,
    chunkBytes: 4096,
  });
  closing.push(async () => exporter.close());
  exporter.setPlaces({ home: HOME, workspaces: [{ workspace: HOME, name: "src" }] });

  // Initial pass discovers Claude + Codex + AGY transcripts, excludes workspace & token files
  const p1 = exporter.pass(nothingTold());
  assert.equal(p1.wrote, 1);
  const head1 = p1.heads[HOME]!;
  assert.ok(head1.transcriptFiles !== undefined);

  // Decode batch and inspect `tr` records
  const genDir = join(replica, "own", HOME, head1.gen);
  const trRecs = head1.batches.flatMap((b) =>
    [...decodeBatch(readFileSync(join(genDir, "log", b))).lines].map((l) => JSON.parse(l)).filter((r) => "tr" in r),
  );
  const trPaths = trRecs.map((r) => r.tr as string);
  assert.ok(trPaths.includes(s.claudeTrPath), "Claude .jsonl discovered");
  assert.ok(trPaths.includes(s.claudeSubPath), "Claude subagent .jsonl discovered");
  assert.ok(trPaths.includes(s.codexTrPath), "Codex rollout discovered");
  assert.ok(trPaths.includes(s.agyDbPath), "AGY conversations/*.db discovered");
  assert.ok(trPaths.includes(s.agyAnnPath), "AGY annotations/*.pbtxt discovered");
  assert.ok(trPaths.includes(s.agyBrainPath), "AGY brain/* discovered");
  assert.ok(!trPaths.includes(s.workspaceSecret), "sessions/*/workspace NEVER backed up");
  assert.ok(!trPaths.includes(s.agyTokenPath), "profile auth token NEVER backed up");

  // 4 KiB chunking: ~10 KiB file -> 3 chunks (4096 + 4096 + remainder)
  const claudeRec1 = trRecs.find((r) => r.tr === s.claudeTrPath)!;
  assert.equal(claudeRec1.chunks.length, 3, "10 KiB file split into 3 chunks of 4 KiB");
  const prefix0 = claudeRec1.chunks[0] as string;
  const prefix1 = claudeRec1.chunks[1] as string;
  const oldTail = claudeRec1.chunks[2] as string;
  assert.ok(existsSync(join(replica, "chunks", oldTail)));

  // Append a new line to Claude transcript -> prefix chunks [0] and [1] 100% reused, oldTail GC'd!
  now += 60_000;
  writeFileSync(s.claudeTrPath, s.claudeInitial + JSON.stringify({ role: "assistant", text: "appended-line" }) + "\n");
  utimesSync(s.claudeTrPath, new Date(1_700_000_060_000), new Date(1_700_000_060_000));
  const p2 = exporter.pass({ ...nothingTold(), transcripts: true });
  assert.equal(p2.wrote, 1);
  const head2 = p2.heads[HOME]!;
  const newBatch = head2.batches[head2.batches.length - 1]!;
  const trRecs2 = [...decodeBatch(readFileSync(join(genDir, "log", newBatch))).lines]
    .map((l) => JSON.parse(l))
    .filter((r) => "tr" in r);
  assert.equal(trRecs2.length, 1, "only changed transcript re-emitted");
  assert.equal(trRecs2[0].tr, s.claudeTrPath);
  assert.equal(trRecs2[0].chunks.length, 3);
  assert.equal(trRecs2[0].chunks[0], prefix0, "chunk 0 hash 100% reused");
  assert.equal(trRecs2[0].chunks[1], prefix1, "chunk 1 hash 100% reused");
  assert.notEqual(trRecs2[0].chunks[2], oldTail, "tail chunk updated");
  assert.equal(head2.transcriptFiles?.[oldTail], undefined, "orphan tail chunk removed from head.transcriptFiles");
  assert.ok(existsSync(join(replica, "chunks", oldTail)), "orphan tail chunk retained on disk during grace period");
  now += CHUNK_GC_GRACE_MS;
  exporter.pass({ ...nothingTold(), transcripts: true });
  assert.ok(!existsSync(join(replica, "chunks", oldTail)), "orphan tail chunk GC'd from disk after grace period");

  // Delete codex session -> its transcript chunk is retained during grace period, then GC'd
  const codexRec = trRecs.find((r) => r.tr === s.codexTrPath)!;
  const codexChunk = codexRec.chunks[0] as string;
  assert.ok(existsSync(join(replica, "chunks", codexChunk)));
  s.store.deleteSession("chat:codex");
  now += 60_000;
  const p3 = exporter.pass({ ...nothingTold(), removedSessions: [{ key: "chat:codex", ws: null }], transcripts: true });
  assert.equal(p3.wrote, 1);
  const head3 = p3.heads[HOME]!;
  assert.equal(head3.transcriptFiles?.[codexChunk], undefined);
  assert.ok(existsSync(join(replica, "chunks", codexChunk)), "deleted session transcript chunk retained during grace period");
  now += CHUNK_GC_GRACE_MS;
  exporter.pass({ ...nothingTold(), transcripts: true });
  assert.ok(!existsSync(join(replica, "chunks", codexChunk)), "deleted session transcript chunk GC'd after grace period");
});

test("E2E (MoonBit reader + Mock S3 + PeerPlace): chunk dedup, includeTranscripts: false, and carriedTo restore", { skip: skipMb }, async () => {
  const s = makeTranscriptStation();
  closing.push(async () => s.store.close());
  const s3WithTr = new MockS3Server();
  const s3NoTr = new MockS3Server();
  await s3WithTr.start();
  await s3NoTr.start();

  const targetWithTr = s3WithTr.target({ id: "r2full", includeTranscripts: true });
  const targetNoTr = s3NoTr.target({ id: "r2chat", includeTranscripts: false });

  const originId = sid("a");
  const peerId = sid("b");
  const clock = testClock();
  const fibersA = new Fibers("copies-a", clock);
  const fibersB = new Fibers("copies-b", clock);
  closing.push(async () => {
    await fibersA.close();
    await fibersB.close();
  });

  // Real MoonBit `stillfail-reader --builder replica-export --chunk-bytes 4096`
  const runnerA = new ProgramRunner({ db: s.db, replica: join(s.data, "replica"), dataDir: s.data, origin: originId, chunkBytes: 4096 });
  closing.push(async () => runnerA.close());

  const dataB = dataDir("tr-peer");
  const storeB = Store.open(join(dataB, "stillfail.db"), join(dataB, "archive"));
  closing.push(async () => storeB.close());
  const runnerB = new InlineRunner({ db: join(dataB, "stillfail.db"), replica: join(dataB, "replica"), dataDir: dataB, origin: peerId, now: () => 1_700_000_000_000 });
  closing.push(async () => runnerB.close());

  const bus = new Map<string, ReturnType<Copies["answers"]>>();
  const ask = async (to: string, req: any): Promise<any> => {
    const h = bus.get(to);
    if (h === undefined) throw new Error("offline");
    return h(to === peerId ? originId : peerId, req, HOME);
  };

  const backupCfg: NormalizedBackupConfig = {
    mode: "manual",
    stations: [peerId],
    acceptOthers: true,
    s3: [targetWithTr, targetNoTr],
  };

  const copiesA = new Copies({
    data: s.data,
    here: () => originId,
    places: () => ({ home: HOME, workspaces: [{ workspace: HOME, name: "station-a" }] }),
    roster: () => [
      { id: originId, name: "station-a" },
      { id: peerId, name: "station-b" },
    ],
    ask,
    runner: runnerA,
    fibers: fibersA,
    changed: () => {},
    restart: async () => null,
    backup: () => backupCfg,
    s3ClientOptions: { now: () => 1_700_000_000_000 },
  });
  const copiesB = new Copies({
    data: dataB,
    here: () => peerId,
    places: () => ({ home: HOME, workspaces: [{ workspace: HOME, name: "station-b" }] }),
    roster: () => [
      { id: originId, name: "station-a" },
      { id: peerId, name: "station-b" },
      { id: sid("d"), name: "station-d" },
    ],
    ask,
    runner: runnerB,
    fibers: fibersB,
    changed: () => {},
    restart: async () => null,
  });
  closing.push(async () => {
    await copiesA.close();
    await copiesB.close();
  });
  bus.set(originId, copiesA.answers());
  bus.set(peerId, copiesB.answers());

  await copiesA.start();
  await copiesA.settle();

  // Verify S3 with includeTranscripts: true received all transcript chunks, while includeTranscripts: false received ZERO!
  const s3PlaceFull = new S3Place(targetWithTr, { now: () => 1_700_000_000_000 });
  const s3PlaceChat = new S3Place(targetNoTr, { now: () => 1_700_000_000_000 });
  const heldFull = await s3PlaceFull.held(HOME, originId);
  const heldChat = await s3PlaceChat.held(HOME, originId);
  assert.equal(heldFull.gens.length, 1);
  const head = heldFull.gens[0]!.head!;
  const tfHashes = Object.keys(head.transcriptFiles ?? {});
  const attHashes = Object.keys(head.files);
  assert.ok(tfHashes.length >= 5, `expected transcript chunks in head.transcriptFiles, got ${tfHashes.length}`);
  assert.equal(attHashes.length, 1, "chat attachment present");

  for (const h of attHashes) {
    assert.ok(heldFull.files.includes(h), "r2full has attachment");
    assert.ok(heldChat.files.includes(h), "r2chat has attachment");
  }
  for (const h of tfHashes) {
    assert.ok(heldFull.files.includes(h), `r2full has transcript chunk ${h}`);
    assert.ok(!heldChat.files.includes(h), `r2chat (includeTranscripts: false) MUST NOT have transcript chunk ${h}`);
    const tag = s3PlaceChat.fileTag(h);
    assert.ok(![...s3NoTr.objects.keys()].some((k) => k.includes(tag)), "no encrypted transcript chunk object in r2chat bucket");
  }

  // Verify PeerPlace also received all transcript chunks
  const heldPeer = await copiesB.kept.held(HOME, originId);
  for (const h of tfHashes) {
    assert.ok(heldPeer.files.includes(h), `PeerPlace has transcript chunk ${h}`);
  }

  // Append to Claude transcript on A, verify only 1 new tail chunk is uploaded to r2full (prefix chunks reused!)
  const putsBefore = s3WithTr.puts.length;
  const claudeAppended = s.claudeInitial + JSON.stringify({ role: "assistant", text: "second-turn-tail" }) + "\n";
  writeFileSync(s.claudeTrPath, claudeAppended);
  utimesSync(s.claudeTrPath, new Date(1_700_000_120_000), new Date(1_700_000_120_000));
  copiesA.told({ type: "session", key: "chat:claude" });
  await copiesA.settle();
  const newFilePuts = s3WithTr.puts.slice(putsBefore).filter((k) => k.includes("/files/"));
  assert.equal(newFilePuts.length, 1, `expected exactly 1 new tail chunk uploaded, got ${newFilePuts.length}`);

  // ── Restore from S3 (r2full) into a brand-new empty station at a DIFFERENT dataDir via real MoonBit takeBackSoon ──
  const dataRestoredS3 = dataDir("tr-restore-s3");
  const dbRestoredS3 = join(dataRestoredS3, "stillfail.db");
  const storeRestoredS3 = Store.open(dbRestoredS3, join(dataRestoredS3, "archive"));
  storeRestoredS3.close();
  const fibersC = new Fibers("copies-c", clock);
  closing.push(async () => fibersC.close());
  const runnerC = new InlineRunner({ db: dbRestoredS3, replica: join(dataRestoredS3, "replica"), dataDir: dataRestoredS3, origin: sid("c"), now: () => 1_700_000_200_000 });
  closing.push(async () => runnerC.close());
  const copiesC = new Copies({
    data: dataRestoredS3,
    here: () => sid("c"),
    places: () => ({ home: HOME, workspaces: [{ workspace: HOME, name: "station-c" }] }),
    roster: () => [{ id: sid("c"), name: "station-c" }],
    ask: async () => { throw new Error("offline"); },
    runner: runnerC,
    fibers: fibersC,
    changed: () => {},
    restart: async () => null,
    backup: () => ({ mode: "manual", stations: [], acceptOthers: true, s3: [targetWithTr, targetNoTr] }),
    s3ClientOptions: { now: () => 1_700_000_200_000 },
  });
  closing.push(async () => copiesC.close());
  await copiesC.start();
  await copiesC.settle();
  await copiesC.restore(HOME, originId, head.gen, { s3: "r2full" });

  // Run real MoonBit `--builder replica-restore`
  const readyS3 = await takeBackSoon(dataRestoredS3, dbRestoredS3, 1_700_000_200_000, binary!);
  assert.ok(readyS3 !== null);

  // Verify Claude transcript was remapped via `carriedTo` to the new dataDir's claudeProject!
  const expectedClaudeRoom = moved(s.claudeRoom, s.data, dataRestoredS3);
  const expectedClaudeProj = claudeProject(expectedClaudeRoom)!;
  assert.notEqual(expectedClaudeProj, claudeProject(s.claudeRoom), "new dataDir has a different claudeProject name");
  const restoredClaudeTr = join(dataRestoredS3, "transcripts", "claude", expectedClaudeProj, `${s.claudeId}.jsonl`);
  assert.ok(existsSync(restoredClaudeTr), `Claude transcript restored at remapped project path: ${restoredClaudeTr}`);
  assert.deepEqual(readFileSync(restoredClaudeTr), Buffer.from(claudeAppended), "Claude transcript byte-for-byte identical");
  assert.equal(statSync(restoredClaudeTr).mode & 0o777, 0o644);

  const restoredClaudeSub = join(dataRestoredS3, "transcripts", "claude", expectedClaudeProj, s.claudeId, "sub-1.jsonl");
  assert.ok(existsSync(restoredClaudeSub), "Claude subagent transcript restored at remapped project path");
  assert.equal(readFileSync(restoredClaudeSub, "utf8"), '{"sub":true}\n');

  const restoredCodexTr = moved(s.codexTrPath, s.data, dataRestoredS3);
  assert.ok(existsSync(restoredCodexTr), "Codex transcript restored");
  assert.equal(readFileSync(restoredCodexTr, "utf8"), s.codexContent);

  const restoredAgyDb = moved(s.agyDbPath, s.data, dataRestoredS3);
  const restoredAgyAnn = moved(s.agyAnnPath, s.data, dataRestoredS3);
  const restoredAgyBrain = moved(s.agyBrainPath, s.data, dataRestoredS3);
  assert.deepEqual(readFileSync(restoredAgyDb), s.agyDbBytes, "AGY binary .db byte-for-byte identical");
  assert.equal(readFileSync(restoredAgyAnn, "utf8"), 'status: "active"\n');
  assert.equal(readFileSync(restoredAgyBrain, "utf8"), "# Plan\n- Step 1\n");

  // Workspace code & auth token MUST NOT exist on restored station
  assert.ok(!existsSync(moved(s.workspaceSecret, s.data, dataRestoredS3)), "workspace code file NOT restored");
  assert.ok(!existsSync(moved(s.agyTokenPath, s.data, dataRestoredS3)), "profile token NOT restored");

  // ── Restore from PeerPlace into another empty station via TS reference `takeBack` ──
  const dataRestoredPeer = dataDir("tr-restore-peer");
  const dbRestoredPeer = join(dataRestoredPeer, "stillfail.db");
  Store.open(dbRestoredPeer, join(dataRestoredPeer, "archive")).close();
  const fibersD = new Fibers("copies-d", clock);
  closing.push(async () => fibersD.close());
  const runnerD = new InlineRunner({ db: dbRestoredPeer, replica: join(dataRestoredPeer, "replica"), dataDir: dataRestoredPeer, origin: sid("d"), now: () => 1_700_000_200_000 });
  closing.push(async () => runnerD.close());
  const copiesD = new Copies({
    data: dataRestoredPeer,
    here: () => sid("d"),
    places: () => ({ home: HOME, workspaces: [{ workspace: HOME, name: "station-d" }] }),
    roster: () => [
      { id: peerId, name: "station-b" },
      { id: sid("d"), name: "station-d" },
    ],
    ask: async (to, req) => {
      assert.equal(to, peerId);
      return copiesB.answers()(sid("d"), req, HOME);
    },
    runner: runnerD,
    fibers: fibersD,
    changed: () => {},
    restart: async () => null,
  });
  closing.push(async () => copiesD.close());
  await copiesD.start();
  await copiesD.settle();
  await copiesD.restore(HOME, originId, head.gen, { station: peerId });
  const readyPeer = takeBack(dataRestoredPeer, dbRestoredPeer, 1_700_000_200_000);
  assert.ok(readyPeer !== null);
  const peerClaudeProj = claudeProject(moved(s.claudeRoom, s.data, dataRestoredPeer))!;
  assert.deepEqual(
    readFileSync(join(dataRestoredPeer, "transcripts", "claude", peerClaudeProj, `${s.claudeId}.jsonl`)),
    Buffer.from(claudeAppended),
    "PeerPlace + TS takeBack restores byte-identical Claude transcript at remapped path",
  );
  assert.deepEqual(readFileSync(moved(s.agyDbPath, s.data, dataRestoredPeer)), s.agyDbBytes);

  // ── Restore from `includeTranscripts: false` S3 target succeeds cleanly without 404 ──
  const dataRestoredNoTr = dataDir("tr-restore-notr");
  const dbRestoredNoTr = join(dataRestoredNoTr, "stillfail.db");
  Store.open(dbRestoredNoTr, join(dataRestoredNoTr, "archive")).close();
  const fibersE = new Fibers("copies-e", clock);
  closing.push(async () => fibersE.close());
  const runnerE = new InlineRunner({ db: dbRestoredNoTr, replica: join(dataRestoredNoTr, "replica"), dataDir: dataRestoredNoTr, origin: sid("e"), now: () => 1_700_000_200_000 });
  closing.push(async () => runnerE.close());
  const copiesE = new Copies({
    data: dataRestoredNoTr,
    here: () => sid("e"),
    places: () => ({ home: HOME, workspaces: [{ workspace: HOME, name: "station-e" }] }),
    roster: () => [{ id: sid("e"), name: "station-e" }],
    ask: async () => { throw new Error("offline"); },
    runner: runnerE,
    fibers: fibersE,
    changed: () => {},
    restart: async () => null,
    backup: () => ({ mode: "manual", stations: [], acceptOthers: true, s3: [targetNoTr] }),
    s3ClientOptions: { now: () => 1_700_000_200_000 },
  });
  closing.push(async () => copiesE.close());
  await copiesE.start();
  await copiesE.settle();
  await copiesE.restore(HOME, originId, head.gen, { s3: "r2chat" });
  const readyNoTr = await takeBackSoon(dataRestoredNoTr, dbRestoredNoTr, 1_700_000_200_000, binary!);
  assert.ok(readyNoTr !== null);
  const outcomeNoTr = JSON.parse(readFileSync(join(dataRestoredNoTr, "replica", "restored.json"), "utf8"));
  assert.equal(outcomeNoTr.error, null, "restore from includeTranscripts:false target has no error");
  assert.ok(outcomeNoTr.missing >= 1, "missing transcript files counted gracefully");
  assert.ok(existsSync(moved(join(s.claudeRoom, "uploads", "note.txt"), s.data, dataRestoredNoTr)), "chat attachment still restored");
});

test("incremental transcript pass budget (files & bytes) and safe tr_del / GC (TS reference + MoonBit reader)", async () => {
  const makeFiveFileStation = (tag: string) => {
    const data = dataDir(tag);
    const db = join(data, "stillfail.db");
    const store = Store.open(db, join(data, "archive"));
    closing.push(async () => store.close());
    const room = join(data, "sessions", "chat", "chat:batch", "workspace");
    mkdirSync(room, { recursive: true });
    const cid = "claude-batch-001";
    store.insertSession({
      key: "chat:batch",
      connect: "chat",
      runtime: "claude",
      profile: "cc",
      workspace: room,
      token: "tok-batch",
      createdAt: 1,
      lastActiveAt: 1,
      ws: null,
    });
    store.setRuntimeSessionId("chat:batch", cid);
    const t = store.openThread("chat", "C", "ts-batch", "Batch Chat", "p@x").id;
    store.joinThread(t, "chat:batch", "chat");
    store.insertMessage({ thread: t, ts: "b.1", authorKind: "person", author: "p@x", text: "hello batch" });

    const proj = claudeProject(room)!;
    const trDir = join(data, "transcripts", "claude", proj);
    mkdirSync(join(trDir, cid), { recursive: true });
    const files: string[] = [];
    const mainPath = join(trDir, `${cid}.jsonl`);
    writeFileSync(mainPath, '{"i":0,"body":"main-transcript-0"}\n');
    files.push(mainPath);
    for (let i = 1; i <= 4; i++) {
      const p = join(trDir, cid, `sub-${i}.jsonl`);
      writeFileSync(p, `{"i":${i},"body":"sub-transcript-${i}"}\n`);
      files.push(p);
    }
    return { data, db, files };
  };

  // 1. TS reference: 5 files with transcriptPassFiles: 2 -> 3 passes (2 + 2 + 1), no spurious tr_del
  const tsSrc = makeFiveFileStation("tr-budget-ts");
  const tsReplica = join(tsSrc.data, "replica");
  let now = 1_700_000_000_000;
  const exporter = new Exporter({
    db: tsSrc.db,
    replica: tsReplica,
    dataDir: tsSrc.data,
    origin: sid("a"),
    now: () => now,
    chunkBytes: 1024,
    transcriptPassFiles: 2,
    fold: false,
  });
  closing.push(async () => exporter.close());
  exporter.setPlaces({ home: HOME, workspaces: [{ workspace: HOME, name: "src" }] });

  const readBatchRecs = (replica: string, head: { gen: string; batches: string[] }, batchIdx: number) => {
    const genDir = join(replica, "own", HOME, head.gen);
    return [...decodeBatch(readFileSync(join(genDir, "log", head.batches[batchIdx]!))).lines].map((l) => JSON.parse(l));
  };

  const p1 = exporter.pass(nothingTold());
  assert.equal(p1.more, true, "pass 1 truncated by transcriptPassFiles=2");
  const head1 = p1.heads[HOME]!;
  const recs1 = readBatchRecs(tsReplica, head1, 0);
  assert.equal(recs1.filter((r) => "tr" in r).length, 2, "pass 1 exports exactly 2 transcript files");
  assert.equal(recs1.filter((r) => "tr_del" in r).length, 0, "pass 1 emits no spurious tr_del");

  now += 1000;
  const p2 = exporter.pass(nothingTold());
  assert.equal(p2.more, true, "pass 2 truncated by transcriptPassFiles=2");
  const head2 = p2.heads[HOME]!;
  const recs2 = readBatchRecs(tsReplica, head2, head2.batches.length - 1);
  assert.equal(recs2.filter((r) => "tr" in r).length, 2, "pass 2 exports next 2 transcript files");
  assert.equal(recs2.filter((r) => "tr_del" in r).length, 0, "pass 2 emits no spurious tr_del");

  now += 1000;
  const p3 = exporter.pass(nothingTold());
  assert.equal(p3.more, false, "pass 3 finishes remaining 1 file");
  const head3 = p3.heads[HOME]!;
  const recs3 = readBatchRecs(tsReplica, head3, head3.batches.length - 1);
  assert.equal(recs3.filter((r) => "tr" in r).length, 1, "pass 3 exports final 1 transcript file");
  assert.equal(recs3.filter((r) => "tr_del" in r).length, 0, "pass 3 emits no tr_del");
  assert.equal(Object.keys(head3.transcriptFiles ?? {}).length, 5, "all 5 transcript chunks present in head");

  // Delete 1 file and run a complete pass -> tr_del emitted and orphan chunk GC'd
  const deletedPath = tsSrc.files[4]!;
  const chunksBefore = new Set(Object.keys(head3.transcriptFiles ?? {}));
  rmSync(deletedPath);
  now += 1000;
  const p4 = exporter.pass({ ...nothingTold(), transcripts: true });
  assert.equal(p4.more, false);
  const head4 = p4.heads[HOME]!;
  const recs4 = readBatchRecs(tsReplica, head4, head4.batches.length - 1);
  const dels4 = recs4.filter((r) => "tr_del" in r).map((r) => r.tr_del);
  assert.deepEqual(dels4, [deletedPath], "complete pass emits tr_del for deleted file");
  const chunksAfter = new Set(Object.keys(head4.transcriptFiles ?? {}));
  assert.equal(chunksAfter.size, 4, "deleted file chunk removed from head.transcriptFiles");
  const orphaned = [...chunksBefore].filter((ch) => !chunksAfter.has(ch));
  assert.equal(orphaned.length, 1);
  for (const ch of orphaned) {
    assert.ok(existsSync(join(tsReplica, "chunks", ch)), "orphan chunk retained on disk during grace period");
  }
  now += CHUNK_GC_GRACE_MS;
  exporter.pass({ ...nothingTold(), transcripts: true });
  for (const ch of orphaned) {
    assert.ok(!existsSync(join(tsReplica, "chunks", ch)), "orphan chunk GC'd from disk after grace period");
  }

  // 2. Single file larger than transcriptPassBytes must still make progress in one pass (no infinite loop)
  const bigData = dataDir("tr-budget-big");
  const bigDb = join(bigData, "stillfail.db");
  const bigStore = Store.open(bigDb, join(bigData, "archive"));
  closing.push(async () => bigStore.close());
  const bigRoom = join(bigData, "sessions", "chat", "chat:big", "workspace");
  mkdirSync(bigRoom, { recursive: true });
  bigStore.insertSession({
    key: "chat:big",
    connect: "chat",
    runtime: "codex",
    profile: "cx",
    workspace: bigRoom,
    token: "tok-big",
    createdAt: 1,
    lastActiveAt: 1,
    ws: null,
  });
  bigStore.setRuntimeSessionId("chat:big", "codex-big-001");
  const tBig = bigStore.openThread("chat", "C", "ts-big", "Big Chat", "p@x").id;
  bigStore.joinThread(tBig, "chat:big", "chat");
  const bigDir = join(bigData, "transcripts", "codex", "2026", "11", "22");
  mkdirSync(bigDir, { recursive: true });
  const bigFile = join(bigDir, "rollout-2026-11-22-codex-big-001.jsonl");
  writeFileSync(bigFile, "A".repeat(1024) + "B".repeat(1024) + "C".repeat(452));
  const bigExporter = new Exporter({
    db: bigDb,
    replica: join(bigData, "replica"),
    dataDir: bigData,
    origin: sid("a"),
    now: () => 1_700_000_000_000,
    chunkBytes: 1024,
    transcriptPassBytes: 512,
  });
  closing.push(async () => bigExporter.close());
  bigExporter.setPlaces({ home: HOME, workspaces: [{ workspace: HOME, name: "big" }] });
  const bigPass = bigExporter.pass(nothingTold());
  assert.equal(bigPass.more, false, "single file exceeding transcriptPassBytes completes in 1 pass");
  assert.equal(Object.keys(bigPass.heads[HOME]!.transcriptFiles ?? {}).length, 3, "2500B file split into 3 chunks of 1024B");

  // 3. MoonBit reader parity for transcriptPassFiles=2 (when binary is built)
  if (binary !== null) {
    const mbSrc = makeFiveFileStation("tr-budget-mb");
    const mbReplica = join(mbSrc.data, "replica");
    const runner = new ProgramRunner({
      db: mbSrc.db,
      replica: mbReplica,
      dataDir: mbSrc.data,
      origin: sid("a"),
      chunkBytes: 1024,
      transcriptPassFiles: 2,
    });
    closing.push(async () => runner.close());
    await runner.places({ home: HOME, workspaces: [{ workspace: HOME, name: "src" }] });

    const mp1 = await runner.pass(nothingTold());
    assert.equal(mp1.more, true, "MB pass 1 truncated by transcriptPassFiles=2");
    assert.equal(Object.keys(mp1.heads[HOME]!.transcriptFiles ?? {}).length, 2);

    const mp2 = await runner.pass(nothingTold());
    assert.equal(mp2.more, true, "MB pass 2 truncated by transcriptPassFiles=2");
    assert.equal(Object.keys(mp2.heads[HOME]!.transcriptFiles ?? {}).length, 4);

    const mp3 = await runner.pass(nothingTold());
    assert.equal(mp3.more, false, "MB pass 3 finishes remaining 1 file");
    assert.equal(Object.keys(mp3.heads[HOME]!.transcriptFiles ?? {}).length, 5);

    rmSync(mbSrc.files[4]!);
    const mp4 = await runner.pass({ ...nothingTold(), transcripts: true });
    assert.equal(mp4.more, false);
    assert.equal(Object.keys(mp4.heads[HOME]!.transcriptFiles ?? {}).length, 4, "MB complete pass deletes and GCs orphan chunk");
  }
});

test("ProgramRunner.close() force-kills a hung worker after closeGraceMs and rejects pending asks", async () => {
  class FakeHungThread extends EventEmitter {
    killed = false;
    posted: unknown[] = [];
    postMessage(m: unknown) {
      this.posted.push(m);
      // Intentionally never replies to simulate a worker stuck in a long pass.
    }
    kill() {
      this.killed = true;
    }
  }
  const fake = new FakeHungThread();
  const runner = new ProgramRunner(
    { db: "/tmp/x.db", replica: "/tmp/r", dataDir: "/tmp/d", origin: sid("a") },
    () => fake,
    25,
  );
  const pendingPass = runner.pass(nothingTold());
  await runner.close();
  assert.equal(fake.killed, true, "hung worker was force-killed after closeGraceMs");
  await assert.rejects(pendingPass, /closed/);
  await assert.rejects(runner.pass(nothingTold()), /closed/);
});

test("Copies.close() closes runner before awaiting hung pass so closeGraceMs force-kill triggers without deadlock", async () => {
  class FakeHungThread extends EventEmitter {
    killed = false;
    postMessage(_m: unknown) {
      // Never replies: simulates replica-export stuck in a long pass.
    }
    kill() {
      this.killed = true;
    }
  }
  const fake = new FakeHungThread();
  const data = dataDir("tr-copies-close");
  const clock = testClock();
  const fibers = new Fibers("copies-close", clock);
  closing.push(async () => fibers.close());
  const runner = new ProgramRunner(
    { db: join(data, "stillfail.db"), replica: join(data, "replica"), dataDir: data, origin: sid("a") },
    () => fake,
    25,
  );
  const copies = new Copies({
    data,
    here: () => sid("a"),
    places: () => ({ home: HOME, workspaces: [{ workspace: HOME, name: "a" }] }),
    roster: () => [{ id: sid("a"), name: "a" }],
    ask: async () => { throw new Error("offline"); },
    runner,
    fibers,
    changed: () => {},
    restart: async () => null,
  });

  // Trigger a stuck pass via told() + gather (1s).
  copies.told({ type: "session", key: "s-hung" });
  await clock.move(1_000);
  // copies.close() must call runner.close() first, triggering fake.kill() after ~25ms and returning cleanly.
  await copies.close();
  assert.equal(fake.killed, true, "Copies.close() triggered ProgramRunner force-kill without deadlocking on #passing");
});

test("Copies pass failure strictly respects exponential backoff even when told() arrives during retry window", async () => {
  const data = dataDir("tr-backoff");
  const clock = testClock();
  const fibers = new Fibers("copies-backoff", clock);
  closing.push(async () => fibers.close());

  let shouldFail = true;
  let passCalls = 0;
  const seenSessions: string[] = [];
  const runner = {
    places: async () => {},
    pass: async (told: ReturnType<typeof nothingTold>) => {
      passCalls++;
      if (shouldFail) throw new Error("database is locked");
      seenSessions.push(...told.sessions);
      return { heads: {}, more: false, wrote: 1, read: 0, empty: false };
    },
    newGenerations: async () => {},
    sources: async () => ({}),
    close: async () => {},
  };

  const copies = new Copies({
    data,
    here: () => sid("a"),
    places: () => ({ home: HOME, workspaces: [{ workspace: HOME, name: "a" }] }),
    roster: () => [{ id: sid("a"), name: "a" }],
    ask: async () => { throw new Error("offline"); },
    runner,
    fibers,
    changed: () => {},
    restart: async () => null,
  });
  closing.push(async () => copies.close());

  // First change triggers gather (1s) -> pass #1 fails -> 5s backoff armed
  copies.told({ type: "session", key: "s1" });
  await clock.move(1_000);
  assert.equal(passCalls, 1);

  // Changes arriving during the 5s backoff must NOT trigger a 1s gather retry
  copies.told({ type: "session", key: "s2" });
  await clock.move(1_000);
  assert.equal(passCalls, 1, "backoff not bypassed at +1s");
  copies.told({ type: "session", key: "s3" });
  await clock.move(3_000);
  assert.equal(passCalls, 1, "backoff not bypassed at +4s");

  // At +5s retry fires, succeeds, and exports all accumulated sessions together
  shouldFail = false;
  await clock.move(1_500);
  assert.equal(passCalls, 2, "retry fired after 5s backoff");
  assert.ok(seenSessions.includes("s1"));
  assert.ok(seenSessions.includes("s2"));
  assert.ok(seenSessions.includes("s3"));
});

async function makeMbExportHelper(db: string, replica: string, data: string, origin: string, chunkBytes = 4096) {
  const proc = new MbProcess(binary!, [
    "--builder",
    "replica-export",
    "--db",
    db,
    "--replica",
    replica,
    "--data-dir",
    data,
    "--origin",
    origin,
    "--sep",
    sep,
    "--chunk-bytes",
    String(chunkBytes),
  ]);
  closing.push(() => proc.terminate().then(() => {}));
  const waiting = new Map<number, { resolve: (v: any) => void; reject: (e: Error) => void }>();
  let next = 0;
  proc.on("message", (m: any) => {
    const w = waiting.get(m.id);
    waiting.delete(m.id);
    if (m.error !== undefined) w?.reject(new Error(m.error));
    else w?.resolve(m.answer);
  });
  proc.on("exit", () => {
    for (const w of waiting.values()) w.reject(new Error("replica-export ended"));
    waiting.clear();
  });
  const ask = (m: Record<string, unknown>, now: number) =>
    new Promise<any>((resolve, reject) => {
      const id = ++next;
      waiting.set(id, { resolve, reject });
      proc.postMessage({ ...m, id, now });
    });
  return {
    places: (now: number) => ask({ type: "places", places: { home: HOME, workspaces: [{ workspace: HOME, name: "src" }] } }, now),
    pass: (told: ReturnType<typeof nothingTold>, now: number) => ask({ type: "pass", told }, now),
    sources: (hashes: string[], now: number) => ask({ type: "sources", hashes }, now) as Promise<Record<string, string>>,
    close: (now: number) => ask({ type: "close" }, now),
  };
}

async function runLongSyncGraceRegression(mode: "ts" | "mb") {
  const s = makeTranscriptStation();
  closing.push(async () => s.store.close());
  const replica = join(s.data, "replica");
  const originId = sid("a");
  const peerId = sid("b");
  let now = 1_700_000_000_000;

  let passFn: (told: ReturnType<typeof nothingTold>) => Promise<any>;
  let sourcesFn: (hashes: string[]) => Promise<Map<string, string>>;
  if (mode === "ts") {
    const exporter = new Exporter({
      db: s.db,
      replica,
      dataDir: s.data,
      origin: originId,
      now: () => now,
      chunkBytes: 4096,
    });
    closing.push(async () => exporter.close());
    exporter.setPlaces({ home: HOME, workspaces: [{ workspace: HOME, name: "src" }] });
    passFn = async (told) => exporter.pass(told);
    sourcesFn = async (hashes) => {
      const m = new Map<string, string>();
      for (const h of hashes) {
        const src = exporter.sourceOf(h);
        if (src !== null) m.set(h, src);
      }
      return m;
    };
  } else {
    const mb = await makeMbExportHelper(s.db, replica, s.data, originId, 4096);
    await mb.places(now);
    passFn = (told) => mb.pass(told, now);
    sourcesFn = async (hashes) => new Map(Object.entries(await mb.sources(hashes, now)));
  }

  const p1 = await passFn(nothingTold());
  const head1 = p1.heads[HOME]!;
  const genDir = join(replica, "own", HOME, head1.gen);
  const trRecs1 = head1.batches.flatMap((b: string) =>
    [...decodeBatch(readFileSync(join(genDir, "log", b))).lines].map((l) => JSON.parse(l)).filter((r) => "tr" in r),
  );
  const claudeRec1 = trRecs1.find((r: any) => r.tr === s.claudeTrPath)!;
  const oldTail = claudeRec1.chunks[2] as string;
  assert.ok(existsSync(join(replica, "chunks", oldTail)));

  // Set up a PeerPlace whose putFile pauses on `oldTail` before `stat(source)` runs.
  const peerDir = dataDir(`tr-grace-peer-${mode}`);
  const peerFolder = new FolderPlace(join(peerDir, "replicas"));
  const peerHandler = serve({ place: peerFolder, inWorkspace: () => true, hello: () => [] });
  let hitOldTail!: () => void;
  const oldTailReached = new Promise<void>((r) => {
    hitOldTail = r;
  });
  let releasePutFile!: () => void;
  const putFileGate = new Promise<void>((r) => {
    releasePutFile = r;
  });
  class PausingPeerPlace extends PeerPlace {
    override async putFile(ws: string, origin: string, hash: string, source: string | Buffer): Promise<void> {
      if (hash === oldTail) {
        hitOldTail();
        await putFileGate;
      }
      return super.putFile(ws, origin, hash, source);
    }
  }
  const peerPlace = new PausingPeerPlace(peerId, async (_to, req) => peerHandler(originId, req, HOME));

  // Start `level()` for head1; it pauses right before PeerPlace.putFile stats `oldTail`.
  const levelPromise = level(peerPlace, HOME, {
    head: head1,
    batch: (name) => readFile(join(genDir, "log", name)),
    sources: sourcesFn,
  });
  await oldTailReached;

  // Simulate 4 rounds of 30s transcript updates (~120s+, spanning > STALE_HEADS_MOST=2) while putFile is in flight.
  const evictedTails: string[] = [oldTail];
  let content = s.claudeInitial;
  let prevTail = oldTail;
  for (let round = 1; round <= 4; round++) {
    now += 30_000;
    content += JSON.stringify({ role: "assistant", text: `turn-append-${round}` }) + "\n";
    writeFileSync(s.claudeTrPath, content);
    utimesSync(s.claudeTrPath, new Date(now), new Date(now));
    const pr = await passFn({ ...nothingTold(), transcripts: true });
    const hr = pr.heads[HOME]!;
    const lastBatch = hr.batches[hr.batches.length - 1]!;
    const recs = [...decodeBatch(readFileSync(join(genDir, "log", lastBatch))).lines]
      .map((l) => JSON.parse(l))
      .filter((r) => "tr" in r && r.tr === s.claudeTrPath);
    assert.equal(recs.length, 1);
    const nextTail = recs[0].chunks[2] as string;
    assert.notEqual(nextTail, prevTail, `round ${round} produced a new tail chunk`);
    if (round < 4) evictedTails.push(nextTail);
    prevTail = nextTail;
  }
  assert.equal(evictedTails.length, 4);
  for (const ch of evictedTails) {
    assert.ok(existsSync(join(replica, "chunks", ch)), `evicted chunk ${ch} stays on disk during grace window`);
  }

  // Release putFile -> level() succeeds on the first try with zero ENOENT!
  releasePutFile();
  const levelled = await levelPromise;
  assert.equal(levelled.behind, false);
  assert.equal(levelled.missing, 0);
  const held = await peerFolder.held(HOME, originId);
  assert.ok(held.files.includes(oldTail), "PeerPlace received oldTail cleanly with zero ENOENT");

  // Advance past CHUNK_GC_GRACE_MS and run a pass -> all 4 evicted tail chunks are GC'd from disk, live tail kept.
  now += CHUNK_GC_GRACE_MS;
  await passFn({ ...nothingTold(), transcripts: true });
  for (const ch of evictedTails) {
    assert.ok(!existsSync(join(replica, "chunks", ch)), `evicted chunk ${ch} GC'd after grace period`);
  }
  assert.ok(existsSync(join(replica, "chunks", prevTail)), "current live tail chunk remains on disk");
}

async function runReReferencedChunkRegression(mode: "ts" | "mb") {
  const s = makeTranscriptStation();
  closing.push(async () => s.store.close());
  const replica = join(s.data, "replica");
  const originId = sid("a");
  let now = 1_700_000_000_000;

  let passFn: (told: ReturnType<typeof nothingTold>) => Promise<any>;
  if (mode === "ts") {
    const exporter = new Exporter({
      db: s.db,
      replica,
      dataDir: s.data,
      origin: originId,
      now: () => now,
      chunkBytes: 4096,
    });
    closing.push(async () => exporter.close());
    exporter.setPlaces({ home: HOME, workspaces: [{ workspace: HOME, name: "src" }] });
    passFn = async (told) => exporter.pass(told);
  } else {
    const mb = await makeMbExportHelper(s.db, replica, s.data, originId, 4096);
    await mb.places(now);
    passFn = (told) => mb.pass(told, now);
  }

  const p1 = await passFn(nothingTold());
  const head1 = p1.heads[HOME]!;
  const genDir = join(replica, "own", HOME, head1.gen);
  const trRecs1 = head1.batches.flatMap((b: string) =>
    [...decodeBatch(readFileSync(join(genDir, "log", b))).lines].map((l) => JSON.parse(l)).filter((r) => "tr" in r),
  );
  const chunkC = trRecs1.find((r: any) => r.tr === s.claudeTrPath)!.chunks[2] as string;
  assert.ok(existsSync(join(replica, "chunks", chunkC)));

  const readGcPending = () => {
    const db = new DatabaseSync(join(replica, "export.db"), { readOnly: true });
    try {
      return (db.prepare("SELECT chunk_hash FROM transcript_chunk_gc ORDER BY chunk_hash").all() as { chunk_hash: string }[]).map((r) => r.chunk_hash);
    } finally {
      db.close();
    }
  };

  // At t0: evict chunk C -> recorded in transcript_chunk_gc, still on disk.
  const t0 = now + 60_000;
  now = t0;
  writeFileSync(s.claudeTrPath, s.claudeInitial + JSON.stringify({ role: "assistant", text: "temp-append" }) + "\n");
  utimesSync(s.claudeTrPath, new Date(now), new Date(now));
  const p2 = await passFn({ ...nothingTold(), transcripts: true });
  assert.equal(p2.heads[HOME]!.transcriptFiles?.[chunkC], undefined);
  assert.ok(existsSync(join(replica, "chunks", chunkC)), "chunk C retained on disk at t0");
  assert.ok(readGcPending().includes(chunkC), "chunk C recorded in transcript_chunk_gc");

  // At t0 + 300_000 (within grace period): restore content so chunk C is re-referenced.
  now = t0 + 300_000;
  writeFileSync(s.claudeTrPath, s.claudeInitial);
  utimesSync(s.claudeTrPath, new Date(now), new Date(now));
  const p3 = await passFn({ ...nothingTold(), transcripts: true });
  assert.notEqual(p3.heads[HOME]!.transcriptFiles?.[chunkC], undefined, "chunk C re-referenced in head.transcriptFiles");
  assert.ok(existsSync(join(replica, "chunks", chunkC)), "chunk C still on disk at t0 + 300s");
  assert.ok(!readGcPending().includes(chunkC), "chunk C cleared from transcript_chunk_gc on re-reference");

  // At t0 + 1_000_000 (past original grace deadline): chunk C must NOT be deleted and transcript_chunk_gc has no residue.
  now = t0 + 1_000_000;
  const p4 = await passFn({ ...nothingTold(), transcripts: true });
  assert.notEqual(p4.heads[HOME]!.transcriptFiles?.[chunkC], undefined);
  assert.ok(existsSync(join(replica, "chunks", chunkC)), "re-referenced chunk C survives past original grace deadline");
  assert.ok(!readGcPending().includes(chunkC), "no transcript_chunk_gc residue for chunk C");
}

test("TS reference + PeerPlace: long sync across 4 rounds of 30s transcript updates hits zero ENOENT", () =>
  runLongSyncGraceRegression("ts"));

test("MoonBit reader + PeerPlace: long sync across 4 rounds of 30s transcript updates hits zero ENOENT", { skip: skipMb }, () =>
  runLongSyncGraceRegression("mb"));

test("TS reference: chunk re-referenced within grace period is not deleted and clears transcript_chunk_gc", () =>
  runReReferencedChunkRegression("ts"));

test("MoonBit reader: chunk re-referenced within grace period is not deleted and clears transcript_chunk_gc", { skip: skipMb }, () =>
  runReReferencedChunkRegression("mb"));
