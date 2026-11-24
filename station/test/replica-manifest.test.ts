// Regression tests for D72a: 2-level 256-bucket `transcriptManifest` read-side pipeline,
// compact local `WorkPassed.heads` IPC vs inline disk `head.json` invariant, fail-closed `drop()`,
// FolderPlace closure validation, S3Place manifest protection & `hasUnverifiedHead`,
// `handOver`/`holdsAllLogical` partial rejection & logical equivalence, `restore`, manifest GC,
// and `Known` manifest cache without skipping chat attachment `oldFiles` or pending `drop()` pages.
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, utimesSync, writeFileSync } from "node:fs";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { join, sep } from "node:path";
import { after, test } from "node:test";
import { zstdCompressSync } from "node:zlib";
import { mbReaderBinary } from "../src/read/mb-reader.ts";
import { Copies, tell } from "../src/replica/copies.ts";
import { type Head, VERSION, asHead } from "../src/replica/format.ts";
import {
  MANIFEST_GC_GRACE_MS,
  MANIFEST_MAX_BYTES,
  MANIFEST_MAX_ENTRIES,
  encodeTranscriptManifest,
  loadLocalTranscriptFiles,
  loadTranscriptManifest,
  parseLeafManifest,
  parseRootManifest,
} from "../src/replica/manifest.ts";
import { FolderPlace, type Held, type Known, type Own, type Place, handOver, holdsAll, holdsAllLogical, level } from "../src/replica/places.ts";
import { ProgramRunner, exportThread } from "../src/replica/runner.ts";
import { S3Place } from "../src/replica/s3.ts";
import type { NormalizedS3Target } from "../src/replica/backup-config.ts";
import { Fibers } from "../src/ops/fibers.ts";
import { Store } from "../src/store/store.ts";
import { Exporter, nothingTold } from "./reference/replica-export.ts";
import { takeBack, takeBackSoon } from "./reference/replica-restore.ts";
import { InlineRunner } from "./reference/replica-work.ts";
import { HOME, attach, dataDir } from "./replica-fakes.ts";
import { testClock } from "./hub-fakes.ts";

const sid = (ch: string) => ch.repeat(64);

const binary = mbReaderBinary();
const skipMb = binary === null ? "the MoonBit program is not built here" : false;
const closing: (() => Promise<void> | void)[] = [];
after(async () => {
  for (const fn of closing.splice(0)) await fn();
});

const sha256 = (data: Buffer | string) => createHash("sha256").update(data).digest("hex");
const hex64 = (prefix: string, fill = "0") => (prefix + fill.repeat(64)).slice(0, 64);

function makeHead(overrides: Partial<Head> = {}): Head {
  return {
    v: VERSION,
    origin: sid("a"),
    workspace: HOME,
    gen: "1-00000001",
    name: "laptop",
    dataDir: "/tmp/a",
    made: 1000,
    to: 1,
    batches: ["0000000001-0000000001-aaaaaaaa.ndjson.zst"],
    files: {},
    chats: 1,
    messages: 1,
    bytes: 100,
    runs: [{ run: "11111111", from: 1 }],
    ...overrides,
  };
}

class MiniS3Server {
  readonly objects = new Map<string, Buffer>();
  server: ReturnType<typeof createServer> | null = null;
  port = 0;

  async start(): Promise<void> {
    this.server = createServer((req: IncomingMessage, res: ServerResponse) => {
      const chunks: Buffer[] = [];
      req.on("data", (c: Buffer) => chunks.push(c));
      req.on("end", () => this.#handle(req, res, Buffer.concat(chunks)));
    });
    await new Promise<void>((resolve) => {
      this.server!.listen(0, "127.0.0.1", () => {
        const addr = this.server!.address();
        this.port = typeof addr === "object" && addr !== null ? addr.port : 0;
        resolve();
      });
    });
  }

  async stop(): Promise<void> {
    if (this.server === null) return;
    const s = this.server;
    this.server = null;
    await new Promise<void>((resolve) => s.close(() => resolve()));
  }

  target(encKeyHex: string, includeTranscripts = true): NormalizedS3Target {
    return {
      id: "s3-test",
      name: "S3 Test",
      endpoint: `http://127.0.0.1:${this.port}`,
      region: "us-east-1",
      bucket: "bkt",
      prefix: "pfx",
      forcePathStyle: true,
      accessKeyId: "AKIA",
      secretAccessKey: "SECRET",
      encryptionKey: encKeyHex,
      includeTranscripts,
    };
  }

  #handle(req: IncomingMessage, res: ServerResponse, body: Buffer): void {
    const u = new URL(req.url ?? "/", `http://127.0.0.1:${this.port}`);
    const parts = u.pathname.replace(/^\/+/, "").split("/");
    const key = parts.slice(1).map(decodeURIComponent).join("/");
    if (req.method === "GET" && u.searchParams.get("list-type") === "2") {
      const prefix = u.searchParams.get("prefix") ?? "";
      const keys = [...this.objects.keys()].filter((k) => k.startsWith(prefix)).sort();
      const xml = `<ListBucketResult><IsTruncated>false</IsTruncated>${keys.map((k) => `<Contents><Key>${k}</Key></Contents>`).join("")}</ListBucketResult>`;
      res.writeHead(200, { "content-type": "application/xml" });
      res.end(xml);
      return;
    }
    if (req.method === "POST" && u.searchParams.has("delete")) {
      const xmlText = body.toString("utf8");
      const deleted: string[] = [];
      const re = /<Key>([^<]+)<\/Key>/g;
      let m: RegExpExecArray | null;
      while ((m = re.exec(xmlText)) !== null) {
        this.objects.delete(m[1]!);
        deleted.push(m[1]!);
      }
      res.writeHead(200, { "content-type": "application/xml" });
      res.end(`<DeleteResult>${deleted.map((k) => `<Deleted><Key>${k}</Key></Deleted>`).join("")}</DeleteResult>`);
      return;
    }
    if (req.method === "PUT") {
      this.objects.set(key, body);
      res.writeHead(200, { etag: `"${sha256(body)}"` });
      res.end();
      return;
    }
    if (req.method === "GET") {
      const data = this.objects.get(key);
      if (data === undefined) {
        res.writeHead(404);
        res.end("<Error><Code>NoSuchKey</Code></Error>");
        return;
      }
      res.writeHead(200);
      res.end(data);
      return;
    }
    res.writeHead(405);
    res.end();
  }
}

function makeTranscriptStation(label: string) {
  const data = dataDir(label);
  const db = join(data, "stillfail.db");
  const store = Store.open(db, join(data, "archive"));
  closing.push(() => store.close());
  const room = join(data, "sessions", "chat", "chat:tr", "workspace");
  mkdirSync(room, { recursive: true });
  store.insertSession({
    key: "chat:tr",
    connect: "chat",
    runtime: "codex",
    profile: "cx",
    workspace: room,
    token: "tok",
    createdAt: 1,
    lastActiveAt: 1,
    ws: null,
  });
  store.setRuntimeSessionId("chat:tr", "codex-tr-001");
  const thread = store.openThread("chat", "C", "ts-tr", "TR Chat", "p@x").id;
  store.joinThread(thread, "chat:tr", "chat");
  const att = attach(data, "chat:tr", "pic.txt", "attachment-bytes");
  store.insertMessage({ thread, ts: "m1", authorKind: "person", author: "p@x", text: "hello", attachments: [att] });
  const trDir = join(data, "transcripts", "codex", "2026", "11", "25");
  mkdirSync(trDir, { recursive: true });
  const trPath = join(trDir, "rollout-2026-11-25-codex-tr-001.jsonl");
  writeFileSync(trPath, "line-0\n".repeat(400) + "line-1\n".repeat(400));
  utimesSync(trPath, new Date(1_700_000_000_000), new Date(1_700_000_000_000));
  return { data, db, store, thread, trPath, att };
}

test("1. Canonical manifest codec, empty set, MoonBit/TS parity, compact IPC vs inline disk head.json, and strict fallback rebuild", async () => {
  // Empty set canonical JSON
  const empty = encodeTranscriptManifest({});
  assert.equal(empty.rootBytes.toString("utf8"), '{"v":1,"buckets":{}}');
  assert.equal(empty.leaves.size, 0);
  const parsedEmpty = parseRootManifest(empty.rootBytes, empty.rootHash);
  assert.deepEqual(parsedEmpty, { v: 1, buckets: {} });

  // 256-bucket sorting
  const hff2 = hex64("ff", "2");
  const hff1 = hex64("ff", "1");
  const h00b = hex64("00", "b");
  const h00a = hex64("00", "a");
  const enc = encodeTranscriptManifest({ [hff2]: 20, [h00b]: 2, [hff1]: 10, [h00a]: 1 });
  assert.deepEqual(Object.keys(enc.buckets), ["00", "ff"]);
  const leaf00 = enc.leaves.get(enc.buckets["00"]!)!;
  assert.equal(leaf00.bytes.toString("utf8"), `{"v":1,"files":{"${h00a}":1,"${h00b}":2}}`);

  // TS Exporter vs MoonBit Exporter parity: compact IPC + inline disk head.json
  const s = makeTranscriptStation("d72a-parity");
  const tsReplica = join(s.data, "replica-ts");
  const mbReplica = join(s.data, "replica-mb");
  const now = 1_700_000_000_000;
  const exp = new Exporter({ db: s.db, replica: tsReplica, dataDir: s.data, origin: sid("a"), now: () => now, chunkBytes: 1024 });
  closing.push(() => exp.close());
  exp.setPlaces({ home: HOME, workspaces: [{ workspace: HOME, name: "src" }] });
  const tsPass = exp.pass(nothingTold());
  const tsHead = tsPass.heads[HOME]!;
  assert.equal(tsHead.transcriptFiles, undefined, "TS IPC head omits transcriptFiles");
  assert.ok(typeof tsHead.transcriptManifest === "string", "TS IPC head carries transcriptManifest");

  // Disk head.json keeps inline transcriptFiles and NO transcriptManifest
  const tsDiskHead = JSON.parse(readFileSync(join(tsReplica, "own", HOME, tsHead.gen, "head.json"), "utf8")) as Head;
  assert.equal(tsDiskHead.transcriptManifest, undefined, "disk head.json must NOT carry transcriptManifest in D72a");
  assert.ok(tsDiskHead.transcriptFiles !== undefined && Object.keys(tsDiskHead.transcriptFiles).length > 0);
  const tsResolved = await loadLocalTranscriptFiles(tsReplica, tsHead);
  assert.deepEqual(tsResolved, tsDiskHead.transcriptFiles);

  // Fallback rebuild from own head.json when local manifests/ deleted: succeeds iff hash matches
  rmSync(join(tsReplica, "manifests"), { recursive: true, force: true });
  const rebuilt = await loadLocalTranscriptFiles(tsReplica, tsHead);
  assert.deepEqual(rebuilt, tsDiskHead.transcriptFiles, "rebuilds from own head.json when canonical root hash matches");

  // Tamper disk head.json transcriptFiles -> recomputed hash mismatches -> MUST throw!
  const tamperedDisk = { ...tsDiskHead, transcriptFiles: { [hex64("aa")]: 999 } };
  writeFileSync(join(tsReplica, "own", HOME, tsHead.gen, "head.json"), JSON.stringify(tamperedDisk));
  await assert.rejects(
    () => loadLocalTranscriptFiles(tsReplica, tsHead),
    /does not match/,
    "mismatching own head.json must throw and never silently drop files",
  );

  // MoonBit parity when binary is present
  if (binary !== null) {
    const runner = new ProgramRunner({ db: s.db, replica: mbReplica, dataDir: s.data, origin: sid("a"), chunkBytes: 1024 }, exportThread);
    closing.push(() => runner.close());
    await runner.places({ home: HOME, workspaces: [{ workspace: HOME, name: "src" }] });
    const mbPass = await runner.pass(nothingTold());
    const mbHead = mbPass.heads[HOME]!;
    assert.equal(mbHead.transcriptFiles, undefined, "MB IPC head omits transcriptFiles");
    assert.ok(typeof mbHead.transcriptManifest === "string", "MB IPC head carries transcriptManifest");
    const mbDiskHead = JSON.parse(readFileSync(join(mbReplica, "own", HOME, mbHead.gen, "head.json"), "utf8")) as Head;
    assert.equal(mbDiskHead.transcriptManifest, undefined, "MB disk head.json keeps inline transcriptFiles");
    assert.ok(mbDiskHead.transcriptFiles !== undefined);
    // Canonical manifest root hash computed by TS on MB's transcriptFiles MUST match MB's root hash byte-for-byte!
    assert.equal(encodeTranscriptManifest(mbDiskHead.transcriptFiles).rootHash, mbHead.transcriptManifest);
    assert.deepEqual(await loadLocalTranscriptFiles(mbReplica, mbHead), mbDiskHead.transcriptFiles);
  }
});

test("2. Adversarial manifest validation: sha256, version, extra keys, duplicate keys, bad bucket, prefix mismatch, invalid compSize, and 64 MiB / 500k bombs", () => {
  const h0a = hex64("0a", "1");
  const h0b = hex64("0b", "2");
  const leafOk = Buffer.from(`{"v":1,"files":{"${h0a}":123}}`, "utf8");
  const leafOkHash = sha256(leafOk);

  // Tampered sha256
  assert.throws(() => parseLeafManifest(leafOk, hex64("ff", "f"), "0a"), /hash mismatch/);
  // Wrong v
  const badV = Buffer.from('{"v":2,"buckets":{}}', "utf8");
  assert.throws(() => parseRootManifest(badV, sha256(badV)), /version/);
  // Extra top-level key
  const extraKey = Buffer.from('{"v":1,"buckets":{},"extra":1}', "utf8");
  assert.throws(() => parseRootManifest(extraKey, sha256(extraKey)), /only keys/);
  // Duplicate JSON key (plain and \u0076 escape)
  const dupTop = Buffer.from('{"v":1,"\\u0076":1,"buckets":{}}', "utf8");
  assert.throws(() => parseRootManifest(dupTop, sha256(dupTop)), /duplicate JSON key/);
  const dupNested = Buffer.from(`{"v":1,"files":{"${h0a}":1,"${h0a}":2}}`, "utf8");
  assert.throws(() => parseLeafManifest(dupNested, sha256(dupNested), "0a"), /duplicate JSON key/);
  // Invalid bucket key
  for (const badB of ["0G", "0", "000", "ZZ"]) {
    const raw = Buffer.from(`{"v":1,"buckets":{"${badB}":"${leafOkHash}"}}`, "utf8");
    assert.throws(() => parseRootManifest(raw, sha256(raw)), /invalid manifest bucket key/);
  }
  // Bucket prefix mismatch
  const mismatch = Buffer.from(`{"v":1,"files":{"${h0b}":10}}`, "utf8");
  assert.throws(() => parseLeafManifest(mismatch, sha256(mismatch), "0a"), /does not match bucket/);
  // Invalid compSize (-1, -0, 1.5, > MAX_SAFE_INTEGER)
  for (const badSz of ["-1", "-0", "1.5", "9007199254740992"]) {
    const raw = Buffer.from(`{"v":1,"files":{"${h0a}":${badSz}}}`, "utf8");
    assert.throws(() => parseLeafManifest(raw, sha256(raw), "0a"));
  }
  // 64 MiB byte cap bomb & 500k entry cap bomb
  assert.throws(() => parseLeafManifest(leafOk, leafOkHash, "0a", { bytes: MANIFEST_MAX_BYTES, entries: 0 }), /max bytes/);
  assert.throws(() => parseLeafManifest(leafOk, leafOkHash, "0a", { bytes: 0, entries: MANIFEST_MAX_ENTRIES }), /max entries/);
  // asHead rejects invalid transcriptManifest
  assert.equal(asHead(makeHead({ transcriptManifest: "not-a-hash" })), null);
  assert.notEqual(asHead(makeHead({ transcriptManifest: leafOkHash, transcriptFiles: { [h0a]: 123 } })), null);
});

test("3 & 4. Dual-field coexistence (union protection), FolderPlace closure validation, fail-closed drop(), and concurrent put(head) vs drop() lock", async () => {
  const dir = dataDir("d72a-folder");
  const place = new FolderPlace(join(dir, "replicas"));
  const origin = sid("a");
  const batch = "0000000001-0000000001-aaaaaaaa.ndjson.zst";
  await place.put(HOME, origin, "1-00000001", "batch", batch, Buffer.from("batch-bytes"));

  const cManifest = hex64("11", "a");
  const cInlineOnly = hex64("22", "b");
  const cUnref = hex64("33", "c");
  const enc = encodeTranscriptManifest({ [cManifest]: 50 });

  // Closure validation: missing root -> rejected
  const headM = makeHead({
    origin,
    batches: [batch],
    transcriptManifest: enc.rootHash,
    transcriptFiles: { [cInlineOnly]: 60 },
  });
  await assert.rejects(() => place.put(HOME, origin, headM.gen, "head", "head.json", Buffer.from(JSON.stringify(headM))), /missing/);

  // Partial head with transcriptManifest -> rejected
  const badPartial = makeHead({ origin, batches: [batch], transcriptManifest: enc.rootHash, partial: true });
  await assert.rejects(() => place.put(HOME, origin, badPartial.gen, "head", "head.json", Buffer.from(JSON.stringify(badPartial))), /partial head/);

  // Put root only, missing leaf -> rejected
  await place.putFile(HOME, origin, enc.rootHash, enc.rootBytes);
  await assert.rejects(() => place.put(HOME, origin, headM.gen, "head", "head.json", Buffer.from(JSON.stringify(headM))), /missing/);

  // Put leaf, missing chunk -> rejected
  for (const [lh, { bytes }] of enc.leaves) await place.putFile(HOME, origin, lh, bytes);
  await assert.rejects(() => place.put(HOME, origin, headM.gen, "head", "head.json", Buffer.from(JSON.stringify(headM))), /not here yet/);

  // Put chunks + inline-only chunk + unreferenced chunk -> put(head) succeeds!
  await place.putFile(HOME, origin, cManifest, Buffer.from("m"));
  await place.putFile(HOME, origin, cInlineOnly, Buffer.from("i"));
  await place.putFile(HOME, origin, cUnref, Buffer.from("u"));
  await place.put(HOME, origin, headM.gen, "head", "head.json", Buffer.from(JSON.stringify(headM)));

  // Dual-field coexistence protection: drop() protects union (root + leaf + cManifest + cInlineOnly) and deletes only cUnref
  const leafHash = [...enc.leaves.keys()][0]!;
  await place.drop(HOME, origin, headM.gen, [], [enc.rootHash, leafHash, cManifest, cInlineOnly, cUnref]);
  assert.notEqual(await place.pathOf(HOME, origin, null, enc.rootHash), null, "root protected");
  assert.notEqual(await place.pathOf(HOME, origin, null, leafHash), null, "leaf protected");
  assert.notEqual(await place.pathOf(HOME, origin, null, cManifest), null, "manifest chunk protected");
  assert.notEqual(await place.pathOf(HOME, origin, null, cInlineOnly), null, "inline coexistence chunk protected");
  assert.equal(await place.pathOf(HOME, origin, null, cUnref), null, "unreferenced file dropped");

  // Concurrent put("head") vs drop() serialized under #withLock
  const cNew = hex64("44", "d");
  const enc2 = encodeTranscriptManifest({ [cManifest]: 50, [cNew]: 70 });
  await place.putFile(HOME, origin, cNew, Buffer.from("n"));
  await place.putFile(HOME, origin, enc2.rootHash, enc2.rootBytes);
  for (const [lh, { bytes }] of enc2.leaves) await place.putFile(HOME, origin, lh, bytes);
  const head2 = makeHead({ origin, batches: [batch], to: 2, made: 2000, transcriptManifest: enc2.rootHash });
  await Promise.all([
    place.put(HOME, origin, head2.gen, "head", "head.json", Buffer.from(JSON.stringify(head2))),
    place.drop(HOME, origin, head2.gen, [], [cNew]),
  ]);
  // Whether drop ran before or after put(head2), if put(head2) won, cNew is still present OR if drop ran before put(head2), put(head2) would reject missing cNew.
  // In our serial order put(head2) was queued first, so cNew MUST survive!
  assert.notEqual(await place.pathOf(HOME, origin, null, cNew), null, "serialized put(head) + drop() protects new chunk");

  // Fail-closed drop(): corrupting manifest leaf aborts drop() and deletes NOTHING
  await place.putFile(HOME, origin, cUnref, Buffer.from("u2"));
  const leaf2Hash = [...enc2.leaves.keys()][0]!;
  writeFileSync(join(place.dir(HOME, origin), "files", leaf2Hash), "corrupted-json");
  place.forget(HOME, origin);
  await assert.rejects(() => place.drop(HOME, origin, head2.gen, [], [cUnref]));
  assert.notEqual(await place.pathOf(HOME, origin, null, cUnref), null, "fail-closed drop() must NOT delete files when manifest is corrupted");

  // Fail-closed drop(): corrupting head.json aborts drop()
  writeFileSync(join(place.dir(HOME, origin), head2.gen, "head.json"), "{broken");
  place.forget(HOME, origin);
  await assert.rejects(() => place.drop(HOME, origin, head2.gen, [], [cUnref]));
  assert.notEqual(await place.pathOf(HOME, origin, null, cUnref), null, "fail-closed drop() must NOT delete files when head.json is corrupted");
});

test("5. S3Place reads transcriptManifest head, protects root+leaves+chunks in held/drop/pruneOrphans, and pauses on corrupted/missing leaf", async () => {
  const srv = new MiniS3Server();
  await srv.start();
  closing.push(() => srv.stop());
  const encKey = "ab".repeat(32);
  const s3 = new S3Place(srv.target(encKey, true), { now: () => 1_700_000_000_000 });
  const origin = sid("a");
  const c1 = hex64("aa", "1");
  const cInline = hex64("bb", "2");
  const cOrphan = hex64("cc", "3");
  const enc = encodeTranscriptManifest({ [c1]: 100 });
  const leafHash = [...enc.leaves.keys()][0]!;

  await s3.putFile(HOME, origin, c1, Buffer.from("chunk-1"));
  await s3.putFile(HOME, origin, cInline, Buffer.from("inline-1"));
  await s3.putFile(HOME, origin, cOrphan, Buffer.from("orphan-1"));
  await s3.putFile(HOME, origin, enc.rootHash, enc.rootBytes);
  await s3.putFile(HOME, origin, leafHash, enc.leaves.get(leafHash)!.bytes);

  const head = makeHead({
    origin,
    transcriptManifest: enc.rootHash,
    transcriptFiles: { [cInline]: 200 },
  });
  await s3.put(HOME, origin, head.gen, "head", "head.json", Buffer.from(JSON.stringify(head)), head);

  // Fresh S3Place reads manifest head: held().files includes root + leaf + c1 + cInline (union!)
  const s3Reader = new S3Place(srv.target(encKey, true), { now: () => 1_700_000_000_000 });
  const held = await s3Reader.held(HOME, origin);
  assert.equal(held.hasUnverifiedHead, undefined);
  assert.ok(held.files.includes(enc.rootHash), "held() includes rootHash");
  assert.ok(held.files.includes(leafHash), "held() includes leafHash");
  assert.ok(held.files.includes(c1), "held() includes manifest chunk");
  assert.ok(held.files.includes(cInline), "held() includes inline coexistence chunk");

  // drop() protects root + leaf + c1; pruneOrphans() removes only cOrphan
  await s3Reader.drop(HOME, origin, head.gen, [], [enc.rootHash, leafHash, c1]);
  await s3Reader.pruneOrphans(HOME, origin, head);
  const afterPrune = await s3Reader.held(HOME, origin);
  assert.ok(afterPrune.files.includes(enc.rootHash));
  assert.ok(afterPrune.files.includes(leafHash));
  assert.ok(afterPrune.files.includes(c1));
  assert.ok(!srv.objects.has(`pfx/${s3Reader.wsTag(HOME)}/${s3Reader.originTag(origin)}/files/${s3Reader.fileTag(cOrphan)}.enc`), "orphan deleted");

  // Now delete the leaf object in S3 and add another orphan -> held() MUST set hasUnverifiedHead and pause drop/pruneOrphans!
  const cOrphan2 = hex64("dd", "4");
  await s3Reader.putFile(HOME, origin, cOrphan2, Buffer.from("orphan-2"));
  const leafS3Key = `pfx/${s3Reader.wsTag(HOME)}/${s3Reader.originTag(origin)}/files/${s3Reader.fileTag(leafHash)}.enc`;
  srv.objects.delete(leafS3Key);

  const s3Broken = new S3Place(srv.target(encKey, true), { now: () => 1_700_000_000_000 });
  const heldBroken = await s3Broken.held(HOME, origin);
  assert.equal(heldBroken.hasUnverifiedHead, true, "missing bucket leaf sets hasUnverifiedHead");
  await s3Broken.drop(HOME, origin, head.gen, [], [cOrphan2, c1]);
  await s3Broken.pruneOrphans(HOME, origin);
  const orphan2Key = `pfx/${s3Broken.wsTag(HOME)}/${s3Broken.originTag(origin)}/files/${s3Broken.fileTag(cOrphan2)}.enc`;
  assert.ok(srv.objects.has(orphan2Key), "drop/pruneOrphans conservatively paused when hasUnverifiedHead is true");
});

test("6. handOver / holdsAll / holdsAllLogical reject partial for full and accept inline vs manifest logical equivalence", async () => {
  const origin = sid("a");
  const c1 = hex64("1a", "1");
  const c2 = hex64("2b", "2");
  const fChat = hex64("3c", "3");
  const enc = encodeTranscriptManifest({ [c1]: 11, [c2]: 22 });
  const leaf1 = enc.buckets["1a"]!;
  const leaf2 = enc.buckets["2b"]!;

  const fullInline = makeHead({ origin, files: { [fChat]: 5 }, transcriptFiles: { [c1]: 11, [c2]: 22 } });
  const partialHeadObj = makeHead({ origin, files: { [fChat]: 5 }, transcriptFiles: { [c1]: 11 }, partial: true });
  const fullManifest = makeHead({ origin, files: { [fChat]: 5 }, transcriptManifest: enc.rootHash });

  // Sync holdsAll rejects partial for full even at same `to`
  const mineInline: Held = { gens: [{ gen: fullInline.gen, head: fullInline, batches: fullInline.batches }], files: [fChat, c1, c2] };
  const theirsPartial: Held = { gens: [{ gen: partialHeadObj.gen, head: partialHeadObj, batches: partialHeadObj.batches }], files: [fChat, c1, c2] };
  assert.equal(holdsAll(mineInline, theirsPartial), false, "partial head must NEVER satisfy full head");

  // Logical equivalence: manifest on `mine` vs inline on `theirs`
  const mineManifest: Held = {
    gens: [{ gen: fullManifest.gen, head: fullManifest, batches: fullManifest.batches }],
    files: [fChat, c1, c2, enc.rootHash, leaf1, leaf2],
  };
  const manifestStore = new Map<string, Buffer>([
    [enc.rootHash, enc.rootBytes],
    [leaf1, enc.leaves.get(leaf1)!.bytes],
    [leaf2, enc.leaves.get(leaf2)!.bytes],
  ]);
  const readMap = async (h: string) => manifestStore.get(h) ?? null;

  assert.equal(
    await holdsAllLogical(mineManifest, mineInline, { readMine: readMap }),
    true,
    "manifest head on mine is logically equivalent to inline head on theirs",
  );
  assert.equal(
    await holdsAllLogical(mineInline, mineManifest, { readTheirs: readMap }),
    true,
    "inline head on mine is logically equivalent to manifest head on theirs",
  );
  assert.equal(
    await holdsAllLogical(mineManifest, theirsPartial, { readMine: readMap }),
    false,
    "holdsAllLogical rejects partial head on theirs",
  );

  // Real FolderPlace handOver: if target only holds partial, handOver MUST push full head!
  const d = dataDir("d72a-handover");
  const fromPlace = new FolderPlace(join(d, "from"));
  const toPlace = new FolderPlace(join(d, "to"));
  const batch = fullInline.batches[0]!;
  await fromPlace.put(HOME, origin, fullInline.gen, "batch", batch, Buffer.from("b"));
  await fromPlace.putFile(HOME, origin, fChat, Buffer.from("chat"));
  await fromPlace.putFile(HOME, origin, c1, Buffer.from("c1"));
  await fromPlace.putFile(HOME, origin, c2, Buffer.from("c2"));
  await fromPlace.put(HOME, origin, fullInline.gen, "head", "head.json", Buffer.from(JSON.stringify(fullInline)));

  await toPlace.put(HOME, origin, fullInline.gen, "batch", batch, Buffer.from("b"));
  await toPlace.putFile(HOME, origin, fChat, Buffer.from("chat"));
  await toPlace.putFile(HOME, origin, c1, Buffer.from("c1"));
  await toPlace.put(HOME, origin, fullInline.gen, "head", "head.json", Buffer.from(JSON.stringify(partialHeadObj)));

  const ok = await handOver(fromPlace, toPlace, HOME, origin);
  assert.equal(ok, true);
  const toHeld = await toPlace.held(HOME, origin);
  assert.equal(toHeld.gens[0]!.head!.partial, undefined, "handOver replaced partial head with full head");
});

test("7. restore with transcriptManifest: normal restore, missing single chunk (chat-first missing count), and corrupted manifest error", async () => {
  const s = makeTranscriptStation("d72a-restore");
  const replica = join(s.data, "replica");
  const origin = sid("a");
  const exp = new Exporter({ db: s.db, replica, dataDir: s.data, origin, now: () => 1_700_000_000_000, chunkBytes: 1024 });
  closing.push(() => exp.close());
  exp.setPlaces({ home: HOME, workspaces: [{ workspace: HOME, name: "src" }] });
  const p = exp.pass(nothingTold());
  const compactHead = p.heads[HOME]!;
  assert.ok(compactHead.transcriptManifest !== undefined);

  // Build a FolderPlace holding the manifest-based head (simulating D72b/manifest remote source)
  const kept = new FolderPlace(join(s.data, "kept"));
  const genDirPath = join(replica, "own", HOME, compactHead.gen);
  for (const b of compactHead.batches) {
    await kept.put(HOME, origin, compactHead.gen, "batch", b, readFileSync(join(genDirPath, "log", b)));
  }
  const tf = await loadLocalTranscriptFiles(replica, compactHead);
  const enc = encodeTranscriptManifest(tf);
  for (const h of Object.keys(compactHead.files)) {
    await kept.putFile(HOME, origin, h, exp.sourceOf(h)!);
  }
  for (const h of Object.keys(tf)) {
    await kept.putFile(HOME, origin, h, exp.sourceOf(h)!);
  }
  await kept.putFile(HOME, origin, enc.rootHash, enc.rootBytes);
  for (const [lh, { bytes }] of enc.leaves) await kept.putFile(HOME, origin, lh, bytes);
  await kept.put(HOME, origin, compactHead.gen, "head", "head.json", Buffer.from(JSON.stringify(compactHead)));

  // Helper to stage restore via Copies.restore() from local `kept`
  const runRestore = async (label: string, mutateKept?: (k: FolderPlace) => void, useMb = false) => {
    const targetData = dataDir(label);
    const clock = testClock();
    Store.open(join(targetData, "stillfail.db"), join(targetData, "archive"), clock.clock).close();
    const fibers = new Fibers("restore-test");
    closing.push(() => fibers.close());
    const runner = new InlineRunner({ db: join(targetData, "stillfail.db"), replica: join(targetData, "replica"), dataDir: targetData, origin: sid("b"), now: () => 1 });
    closing.push(() => runner.close());
    const copies = new Copies({
      data: targetData,
      here: () => sid("b"),
      places: () => ({ home: HOME, workspaces: [{ workspace: HOME, name: "dst" }] }),
      roster: () => [{ id: sid("b"), name: "dst" }],
      ask: async () => { throw new Error("unused"); },
      runner,
      fibers,
      changed: () => {},
      restart: async () => null,
    });
    closing.push(() => copies.close());
    // Copy kept into copies.kept
    const srcHeld = await kept.held(HOME, origin);
    for (const f of srcHeld.files) {
      await copies.kept.putFile(HOME, origin, f, (await kept.read(HOME, origin, null, f))!);
    }
    for (const g of srcHeld.gens) {
      for (const b of g.batches) await copies.kept.put(HOME, origin, g.gen, "batch", b, (await kept.read(HOME, origin, g.gen, b))!);
      if (g.head !== null) await copies.kept.put(HOME, origin, g.gen, "head", "head.json", Buffer.from(JSON.stringify(g.head)));
    }
    mutateKept?.(copies.kept);
    await copies.placesChanged();
    await copies.settle();
    await copies.restore(HOME, origin, compactHead.gen, { station: sid("b") });
    await copies.close();
    if (useMb && binary !== null) {
      await takeBackSoon(targetData, join(targetData, "stillfail.db"), 10, binary);
    } else {
      takeBack(targetData, join(targetData, "stillfail.db"), 10);
    }
    return JSON.parse(readFileSync(join(targetData, "replica", "restored.json"), "utf8"));
  };

  // 7a. Normal manifest restore (TS + MB)
  const okTs = await runRestore("d72a-res-ok-ts");
  assert.equal(okTs.error, null);
  assert.equal(okTs.missing, 0);
  assert.ok(okTs.files >= 2);
  if (binary !== null) {
    const okMb = await runRestore("d72a-res-ok-mb", undefined, true);
    assert.equal(okMb.error, null);
    assert.equal(okMb.missing, 0);
    assert.equal(okMb.files, okTs.files);
  }

  // 7b. Missing single transcript chunk -> chat DB & attachment still restore, transcript recorded in `missing`
  const oneChunk = Object.keys(tf)[0]!;
  const missingChunkRes = await runRestore("d72a-res-miss-chunk", (k) => {
    rmSync(join(k.dir(HOME, origin), "files", oneChunk));
  });
  assert.equal(missingChunkRes.error, null, "missing single transcript chunk does NOT fail restore");
  assert.equal(missingChunkRes.missing, 1, "missing transcript counted in outcome.missing");
  assert.ok(missingChunkRes.files >= 1, "chat attachment still placed");

  // 7c. Corrupted manifest leaf -> restore MUST fail!
  const oneLeaf = [...enc.leaves.keys()][0]!;
  await assert.rejects(
    () => runRestore("d72a-res-bad-manifest", (k) => {
      writeFileSync(join(k.dir(HOME, origin), "files", oneLeaf), "tampered-leaf");
    }),
    /hash mismatch/,
    "corrupted manifest leaf fails restore during bring",
  );

  // 7d. Direct takeBack / takeBackSoon with tampered manifest leaf on disk -> outcome.error set!
  const badDirect = dataDir("d72a-res-direct-bad");
  const clock = testClock();
  Store.open(join(badDirect, "stillfail.db"), join(badDirect, "archive"), clock.clock).close();
  const copy = join(badDirect, "restore", "copy");
  mkdirSync(join(copy, compactHead.gen, "log"), { recursive: true });
  mkdirSync(join(copy, "files"), { recursive: true });
  for (const b of compactHead.batches) {
    writeFileSync(join(copy, compactHead.gen, "log", b), readFileSync(join(genDirPath, "log", b)));
  }
  writeFileSync(join(copy, compactHead.gen, "head.json"), JSON.stringify(compactHead));
  writeFileSync(join(copy, "files", enc.rootHash), enc.rootBytes);
  writeFileSync(join(copy, "files", oneLeaf), "corrupted-on-disk");
  writeFileSync(join(badDirect, "restore", "ready.json"), JSON.stringify({ origin, workspace: HOME, gen: compactHead.gen, name: "src", from: "x" }));
  if (binary !== null) {
    await takeBackSoon(badDirect, join(badDirect, "stillfail.db"), 20, binary);
  } else {
    takeBack(badDirect, join(badDirect, "stillfail.db"), 20);
  }
  const directOutcome = JSON.parse(readFileSync(join(badDirect, "replica", "restored.json"), "utf8"));
  assert.notEqual(directOutcome.error, null, "corrupted manifest fails takeBack/takeBackSoon");
  assert.equal(directOutcome.reason, "error");
});

test("8. <replica>/manifests/ 10-minute mtime grace GC keeps live and recent manifests and removes stale unreferenced ones", () => {
  const s = makeTranscriptStation("d72a-gc");
  const replica = join(s.data, "replica");
  let now = 1_700_000_000_000;
  const exp = new Exporter({ db: s.db, replica, dataDir: s.data, origin: sid("a"), now: () => now, chunkBytes: 1024 });
  closing.push(() => exp.close());
  exp.setPlaces({ home: HOME, workspaces: [{ workspace: HOME, name: "src" }] });

  const p1 = exp.pass(nothingTold());
  const oldRoot = p1.heads[HOME]!.transcriptManifest!;
  assert.ok(existsSync(join(replica, "manifests", oldRoot)));

  // Modify transcript so a new manifest root is written; oldRoot becomes unreferenced
  now += 60_000;
  writeFileSync(s.trPath, "updated-content-" + "x".repeat(2000));
  utimesSync(s.trPath, new Date(now), new Date(now));
  const p2 = exp.pass({ ...nothingTold(), transcripts: true });
  const newRoot = p2.heads[HOME]!.transcriptManifest!;
  assert.notEqual(newRoot, oldRoot);

  // Set oldRoot mtime to 5 minutes ago (< 10 min grace) -> MUST be kept
  const fiveMinAgo = new Date(now - 5 * 60_000);
  utimesSync(join(replica, "manifests", oldRoot), fiveMinAgo, fiveMinAgo);
  exp.pass({ ...nothingTold(), transcripts: true });
  assert.ok(existsSync(join(replica, "manifests", oldRoot)), "unreferenced manifest kept within 10-min mtime grace");
  assert.ok(existsSync(join(replica, "manifests", newRoot)), "live manifest kept");

  // Set oldRoot mtime to >= 10 minutes ago -> MUST be removed, while live newRoot (even with old mtime) MUST stay!
  const elevenMinAgo = new Date(now - MANIFEST_GC_GRACE_MS - 60_000);
  utimesSync(join(replica, "manifests", oldRoot), elevenMinAgo, elevenMinAgo);
  utimesSync(join(replica, "manifests", newRoot), elevenMinAgo, elevenMinAgo);
  exp.pass({ ...nothingTold(), transcripts: true });
  assert.ok(!existsSync(join(replica, "manifests", oldRoot)), "stale unreferenced manifest GC'd past 10-min grace");
  assert.ok(existsSync(join(replica, "manifests", newRoot)), "live manifest NEVER GC'd regardless of mtime");
});

test("9. Known manifest cache hit skips loadTranscriptFiles on unchanged transcriptManifest while still dropping deleted chat attachments and pending drop pages", async () => {
  const origin = sid("a");
  const c1 = hex64("11", "1");
  const c2 = hex64("22", "2");
  const att1 = hex64("aa", "1");
  const att2 = hex64("bb", "2");
  const attOld1 = hex64("cc", "3");
  const attOld2 = hex64("dd", "4");
  const batch1 = "0000000001-0000000001-aaaaaaaa.ndjson.zst";
  const batch2 = "0000000002-0000000002-bbbbbbbb.ndjson.zst";
  const enc = encodeTranscriptManifest({ [c1]: 10, [c2]: 20 });

  const storedFiles = new Set<string>([att1, att2, attOld1, attOld2, c1, c2]);
  const storedBatches = new Set<string>([batch1]);
  const droppedPages: string[][] = [];
  let putHeadCount = 0;
  let lastWireHead: Head | null = null;
  let failSecondDropPage = true;

  const fakePlace: Place = {
    async held() {
      return {
        gens: [{ gen: "1-00000001", head: null, batches: [...storedBatches] }],
        files: [...storedFiles],
      };
    },
    async put(_ws, _origin, _gen, kind, name, bytes, head) {
      if (kind === "batch") storedBatches.add(name);
      else {
        putHeadCount++;
        lastWireHead = head ?? (JSON.parse(bytes.toString("utf8")) as Head);
      }
    },
    async putFile(_ws, _origin, hash) {
      storedFiles.add(hash);
    },
    async drop(_ws, _origin, _gen, _batches, files) {
      if (failSecondDropPage && droppedPages.length === 1) {
        failSecondDropPage = false;
        throw new Error("simulated drop page failure");
      }
      droppedPages.push([...files]);
      for (const f of files) storedFiles.delete(f);
    },
  };

  let loadCalls = 0;
  const makeOwn = (head: Head): Own => ({
    head,
    batch: async () => Buffer.from("b"),
    sources: async (hashes) => new Map(hashes.map((h) => [h, `/fake/${h}`])),
    loadTranscriptFiles: async () => {
      loadCalls++;
      return { [c1]: 10, [c2]: 20 };
    },
  });

  // Round 1: initial level with compact manifest head, dropFilesPage=1 -> page 1 drops attOld1, page 2 fails (leaving attOld2 pending!)
  const head1 = makeHead({ origin, batches: [batch1], files: { [att1]: 5, [att2]: 6 }, transcriptManifest: enc.rootHash, to: 1, made: 1000 });
  // First level fails on 2nd drop page; we can simulate Known after page 1 succeeded (attOld2 still in k.files)
  await assert.rejects(() => level(fakePlace, HOME, makeOwn(head1), null, { dropFilesPage: 1 }), /simulated drop page failure/);
  assert.equal(loadCalls, 1);
  assert.equal(putHeadCount, 1);
  // Wire head MUST be inline transcriptFiles (D72a iron law)!
  assert.equal(lastWireHead!.transcriptManifest, undefined, "wire head must NOT carry transcriptManifest in D72a");
  assert.deepEqual(lastWireHead!.transcriptFiles, { [c1]: 10, [c2]: 20 });

  // Build Known representing confirmed manifest + pending attOld2 still in place
  const knownAfterPartialDrop: Known = {
    gen: head1.gen,
    batches: new Set([batch1]),
    files: new Set([att1, att2, attOld2, c1, c2]),
    others: new Set(),
    to: 1,
    made: 1000,
    manifest: {
      gen: head1.gen,
      strategy: "with-transcripts",
      rootHash: enc.rootHash,
      transcriptFiles: { [c1]: 10, [c2]: 20 },
      tfCount: 2,
      complete: true,
    },
  };

  // Round 2: chat attachment `att2` deleted, `transcriptManifest` UNCHANGED!
  // Known cache MUST hit (loadCalls stays 1!) AND MUST still drop BOTH `att2` (deleted chat attachment) AND `attOld2` (pending drop page)!
  const head2 = makeHead({ origin, batches: [batch1, batch2], files: { [att1]: 5 }, transcriptManifest: enc.rootHash, to: 2, made: 2000 });
  const res2 = await level(fakePlace, HOME, makeOwn(head2), knownAfterPartialDrop, { dropFilesPage: 1 });
  assert.equal(res2.behind, false);
  assert.equal(loadCalls, 1, "Known manifest cache hit MUST NOT re-call loadTranscriptFiles");
  assert.equal(storedFiles.has(att2), false, "deleted chat attachment att2 was reclaimed");
  assert.equal(storedFiles.has(attOld2), false, "pending drop page file attOld2 was reclaimed");
  assert.equal(storedFiles.has(att1), true, "live chat attachment att1 kept");
  assert.equal(storedFiles.has(c1), true, "live transcript c1 kept");
  assert.equal(storedFiles.has(c2), true, "live transcript c2 kept");
});
