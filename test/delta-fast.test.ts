import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { crc32, deflateRawSync, inflateRawSync } from "node:zlib";
import { CHUNK, apply, applyFile, ensureNativeDelta, makeApk, makeDelta, makeTree, makeTreeFromBuffer, parseHeader, readOld, sameBlocks, wholeFiles, type Range } from "../scripts/delta.ts";
import * as delta from "../scripts/delta.ts";

// scripts/delta-fast.c makes what delta.ts's own search makes: the same bsdiff records byte for byte (only their
// deflating may differ, zlib's against node's), so every delta it makes gives the package back.

const native = spawnSync("cc", ["--version"]).status === 0 ? ensureNativeDelta() : null;
const skip = native ? false : "no C compiler with zlib here: delta-fast.c not tested";

function prng(seed: number) {
  return () => {
    seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
const random = (rand: () => number, n: number) => { const b = Buffer.alloc(n); for (let i = 0; i < n; i++) b[i] = (rand() * 256) | 0; return b; };
const texty = (rand: () => number, n: number) => {
  const words = Array.from({ length: 64 }, () => random(rand, 2 + Math.floor(rand() * 10)));
  const out: Buffer[] = [];
  for (let size = 0; size < n;) { const w = words[Math.floor(rand() * words.length)]!; out.push(w); size += w.length; }
  return Buffer.concat(out).subarray(0, n);
};
const edited = (rand: () => number, b: Buffer, every: number) => {
  const c = Buffer.from(b);
  for (let at = Math.floor(rand() * every); at < c.length; at += 1 + Math.floor(rand() * every)) c[at] = (rand() * 256) | 0;
  return c;
};

/** `fn` with these environment variables (undefined: unset), as they were after. */
function withEnv<T>(vars: Record<string, string | undefined>, fn: () => T): T {
  const before = Object.fromEntries(Object.keys(vars).map((k) => [k, process.env[k]]));
  const set = (v: Record<string, string | undefined>) => { for (const [k, x] of Object.entries(v)) if (x === undefined) delete process.env[k]; else process.env[k] = x; };
  set(vars);
  try { return fn(); } finally { set(before); }
}
const inC = <T>(fn: () => T) => withEnv({ STILLFAIL_DELTA_FAST_FORCE: "1", STILLFAIL_DELTA_JS: undefined }, () => {
  const r = fn();
  assert.equal(delta.lastMaker, "native", "made by delta-fast.c");
  return r;
});
const inJs = <T>(fn: () => T) => withEnv({ STILLFAIL_DELTA_FAST_FORCE: undefined, STILLFAIL_DELTA_JS: "1" }, () => {
  const r = fn();
  assert.equal(delta.lastMaker, "js");
  return r;
});

/** The bsdiff records of a delta: its chunks inflated, one after another. */
function records(d: Buffer): Buffer {
  const out: Buffer[] = [];
  for (let at = parseHeader(d).payload!; ;) {
    const raw = d.readUInt32LE(at), packed = d.readUInt32LE(at + 4);
    if (raw === 0) break;
    out.push(inflateRawSync(d.subarray(at + 8, at + 8 + packed)));
    at += 8 + packed;
  }
  return Buffer.concat(out);
}

/** What a delta made of the old blob gives back: the package, byte for byte. */
function gives(d: Buffer, old: Buffer, made: Buffer) {
  const out: Buffer[] = [];
  apply(parseHeader(d), old, d, (b) => out.push(Buffer.from(b)));
  assert.ok(Buffer.concat(out).equals(made), "the delta gives the package");
}

const blobOf = (parts: Buffer[]) => {
  const ranges = [];
  for (let at = 0, i = 0; i < parts.length; at += parts[i]!.length, i++) ranges.push({ at, len: parts[i]!.length });
  return { blob: Buffer.concat(parts), ranges };
};

test("delta-fast.c's records are delta.ts's, on small and odd inputs", { skip }, () => {
  const rand = prng(42);
  const base = texty(rand, 50_000);
  const cases: [string, Buffer, Buffer][] = [
    ["nothing to nothing", Buffer.alloc(0), Buffer.alloc(0)],
    ["nothing to some", Buffer.alloc(0), random(rand, 3000)],
    ["some to nothing", random(rand, 3000), Buffer.alloc(0)],
    ["one byte each", Buffer.from([7]), Buffer.from([9])],
    ["two bytes", Buffer.from([1, 1]), Buffer.from([1, 1, 1])],
    ["zeros", Buffer.alloc(200_000), Buffer.concat([Buffer.alloc(100_000), Buffer.from("x"), Buffer.alloc(150_000)])],
    ["a byte said over", Buffer.alloc(70_000, 0xaa), Buffer.alloc(90_000, 0xab)],
    ["shifted and edited", base, Buffer.concat([random(rand, 777), edited(rand, base.subarray(20_000), 3000), base.subarray(0, 20_000)])],
    ["random to random", random(rand, 40_000), random(rand, 40_000)],
  ];
  for (const [what, old, made] of cases) {
    const c = inC(() => makeDelta(old, made, [], [], []));
    const js = inJs(() => makeDelta(old, made, [], [], []));
    gives(c, old, made);
    assert.ok(records(c).equals(records(js)), `${what}: the same records`);
  }
});

test("delta-fast.c with the old files found whole (sparse) and with too few found (the whole blob sorted)", { skip }, () => {
  const rand = prng(9570);
  const kept = [texty(rand, 30_000), random(rand, 12_000), texty(rand, 200_000)], big = texty(rand, 300_000);
  const old = blobOf([kept[0]!, big, kept[1]!, kept[2]!]);
  const shifted = Buffer.concat([big.subarray(0, 100_000), random(rand, 300), edited(rand, big.subarray(100_000), 20_000)]);
  const sparse = Buffer.concat([kept[2]!, shifted, random(rand, 5000), kept[0]!, kept[1]!]);
  const runs = sameBlocks(old.blob, sparse, wholeFiles(old.blob, old.ranges, sparse));
  assert.ok(runs.length > 3);
  const few = blobOf([random(rand, 100_000), kept[1]!, random(rand, 90_000)]);
  const whole = Buffer.concat([edited(rand, few.blob.subarray(0, 100_000), 50), kept[1]!, random(rand, 20_000)]);
  assert.ok(wholeFiles(few.blob, few.ranges, whole).reduce((n, r) => n + r.len, 0) < few.blob.length / 8);
  for (const [what, o, made] of [["sparse", old, sparse], ["whole", few, whole]] as const) {
    const c = inC(() => makeDelta(o.blob, made, [], [], [], o.ranges));
    const js = inJs(() => makeDelta(o.blob, made, [], [], [], o.ranges));
    gives(c, o.blob, made);
    assert.ok(records(c).equals(records(js)), `${what}: the same records`);
  }
});

test("delta-fast.c takes runs that overlap, as sameBlocks makes them where a block followed back reaches a run before it", { skip }, () => {
  const rand = prng(10321);
  const r1 = random(rand, 2048), z = random(rand, 2048);
  // (made's Z is found at old's 2560 and followed back over R1's last 512 bytes, which old has before it too)
  const old = Buffer.concat([r1, r1.subarray(1536), z]), made = Buffer.concat([r1, z, random(rand, 300)]);
  const runs = sameBlocks(old, made, []);
  assert.ok(runs.some((r, i) => i > 0 && runs[i - 1]!.made + runs[i - 1]!.len > r.made), `overlapping runs: ${JSON.stringify(runs)}`);
  const parts = blobOf([r1, r1.subarray(1536), z]);
  const c = inC(() => makeDelta(old, made, [], [], [], parts.ranges));
  const js = inJs(() => makeDelta(old, made, [], [], [], parts.ranges));
  gives(c, old, made);
  assert.ok(records(c).equals(records(js)), "the same records");
});

test("a folder's and an apk's delta made by delta-fast.c give the package back", { skip }, (t) => {
  const dir = mkdtempSync(join(tmpdir(), "delta-fast-test-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const rand = prng(8147);
  const files: Record<string, Buffer> = { "a/app": texty(rand, 120_000), "a/lib.so": random(rand, 60_000), "b/data": texty(rand, 40_000) };
  for (const [p, b] of Object.entries(files)) { mkdirSync(dirname(join(dir, "old", p)), { recursive: true }); writeFileSync(join(dir, "old", p), b); }
  const neu = Buffer.concat([files["b/data"]!, edited(rand, files["a/app"]!, 9000), Buffer.from("tar-ish"), files["a/lib.so"]!]);
  writeFileSync(join(dir, "new"), neu);
  inC(() => makeTree(join(dir, "old"), join(dir, "new"), join(dir, "d.delta")));
  const d = readFileSync(join(dir, "d.delta")), out: Buffer[] = [];
  apply(parseHeader(d), readOld(parseHeader(d), { dir: join(dir, "old") }), d, (b) => out.push(Buffer.from(b)));
  assert.ok(Buffer.concat(out).equals(neu));
  // (an apk: one entry deflated in both, changed; one stored)
  const js = texty(rand, 80_000), lib = random(rand, 30_000);
  writeFileSync(join(dir, "old.apk"), zip([["index.bundle", js, true], ["lib.so", lib, false]]));
  writeFileSync(join(dir, "new.apk"), zip([["index.bundle", Buffer.concat([js.subarray(0, 40_000), Buffer.from("8147"), js.subarray(40_000)]), true], ["lib.so", edited(rand, lib, 5000), false]]));
  assert.equal(inC(() => makeApk(join(dir, "old.apk"), join(dir, "new.apk"), join(dir, "a.delta"))), 1);
  // (makeApk check="skip" produces the exact same delta bytes)
  assert.equal(inC(() => makeApk(join(dir, "old.apk"), join(dir, "new.apk"), join(dir, "a-skip.delta"), "skip")), 1);
  assert.ok(readFileSync(join(dir, "a-skip.delta")).equals(readFileSync(join(dir, "a.delta"))));
  // (makeTreeFromBuffer produces the exact same delta bytes as makeTree)
  const ordered = Object.keys(files).sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b)));
  const bufs = ordered.map((k) => files[k]!);
  const ranges: Range[] = [];
  for (let at = 0, i = 0; i < bufs.length; at += bufs[i]!.length, i++) ranges.push({ at, len: bufs[i]!.length });
  inC(() => makeTreeFromBuffer(ordered, ranges, Buffer.concat(bufs), join(dir, "new"), join(dir, "d-buf.delta")));
  assert.ok(readFileSync(join(dir, "d-buf.delta")).equals(readFileSync(join(dir, "d.delta"))));
});

test("delta-fast --files matches JS wholeFiles + sameBlocks + 4-arg delta-fast byte for byte", { skip }, (t) => {
  const dir = mkdtempSync(join(tmpdir(), "delta-fast-files-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const bin = native!;
  const runBoth = (what: string, old: Buffer, made: Buffer, oldFiles: Range[]) => {
    const oldPath = join(dir, "old"), madePath = join(dir, "made");
    const runsPath = join(dir, "runs"), filesPath = join(dir, "files");
    const out4 = join(dir, "out4"), outFiles = join(dir, "outFiles");
    writeFileSync(oldPath, old);
    writeFileSync(madePath, made);
    const runs = sameBlocks(old, made, oldFiles.length ? wholeFiles(old, oldFiles, made) : []);
    const runsBin = Buffer.alloc(runs.length * 12);
    runs.forEach((r, i) => { runsBin.writeUInt32LE(r.made, i * 12); runsBin.writeUInt32LE(r.old, i * 12 + 4); runsBin.writeUInt32LE(r.len, i * 12 + 8); });
    writeFileSync(runsPath, runsBin);
    const filesBin = Buffer.alloc(oldFiles.length * 8);
    oldFiles.forEach((f, i) => { filesBin.writeUInt32LE(f.at, i * 8); filesBin.writeUInt32LE(f.len, i * 8 + 4); });
    writeFileSync(filesPath, filesBin);
    execFileSync(bin, [oldPath, madePath, runsPath, out4], { stdio: ["ignore", "ignore", "pipe"] });
    execFileSync(bin, ["--files", oldPath, madePath, filesPath, outFiles], { stdio: ["ignore", "ignore", "pipe"] });
    const b4 = readFileSync(out4), bf = readFileSync(outFiles);
    assert.ok(bf.equals(b4), `${what}: --files output (${bf.length} B) must match 4-arg output (${b4.length} B) byte for byte`);
  };

  const rand = prng(314159);
  // 1) Multi-file with same-prefix tie-breaking (len DESC, at ASC), short files, flat/zero blocks, and shifted large blocks
  const prefix = random(rand, 256);
  const fShort = random(rand, 100);
  const fFlat = Buffer.alloc(4096, 0x00);
  const fFlatAA = Buffer.alloc(1024, 0xaa);
  const fSamePrefixShort = Buffer.concat([prefix, random(rand, 400)]);
  const fSamePrefixLong = Buffer.concat([prefix, random(rand, 2000)]);
  const fSamePrefixDup1 = Buffer.from(fSamePrefixLong);
  const fSamePrefixDup2 = Buffer.from(fSamePrefixLong);
  const fBig = texty(rand, 180_000);
  const multi = blobOf([fShort, fFlat, fSamePrefixShort, fSamePrefixDup1, fFlatAA, fSamePrefixDup2, fBig]);
  const multiMade = Buffer.concat([
    Buffer.alloc(3000, 0x00),
    fSamePrefixDup1,
    random(rand, 333),
    fSamePrefixShort,
    Buffer.alloc(1500, 0xaa),
    fBig.subarray(90_000),
    random(rand, 123),
    fBig.subarray(0, 90_000),
    fShort,
  ]);
  runBoth("multi-file + tie-break + flat + shifted", multi.blob, multiMade, multi.ranges);

  // 2) Same-hash collision candidates where first (longer) fails memcmp and second (shorter) matches
  const fColLong = Buffer.concat([prefix, Buffer.from("A".repeat(1000))]);
  const fColMid = Buffer.concat([prefix, Buffer.from("B".repeat(600))]);
  const fColShort = Buffer.concat([prefix, Buffer.from("C".repeat(300))]);
  const col = blobOf([fColLong, fColMid, fColShort, random(rand, 4000)]);
  const colMade = Buffer.concat([random(rand, 50), fColShort, random(rand, 50), fColMid, random(rand, 50), fColLong]);
  runBoth("same-prefix hash bucket fallback", col.blob, colMade, col.ranges);

  // 3) Empty files list (sameBlocks only) with overlapping backward extension & repeated zero stretches
  const r1 = random(rand, 2048), z = random(rand, 2048);
  const ovOld = Buffer.concat([Buffer.alloc(4096), r1, r1.subarray(1536), z, Buffer.alloc(4096, 0x55)]);
  const ovMade = Buffer.concat([Buffer.alloc(2048), r1, z, random(rand, 300), Buffer.alloc(4096, 0x55)]);
  runBoth("empty files list + overlapping sameBlocks", ovOld, ovMade, []);
});

test("from PREFIXED_FROM old bytes delta-fast.c makes the delta by itself, the same records as delta.ts's, its size alike", { skip }, (t) => {
  const rand = prng(2026);
  const old = texty(rand, 2 << 20);
  const made = Buffer.concat([old.subarray(0, 500_000), random(rand, 4000), edited(rand, old.subarray(500_000, 1_500_000), 4000), old.subarray(1_600_000)]);
  const time = (fn: () => Buffer) => { const at = performance.now(); const d = fn(); return { d, ms: performance.now() - at }; };
  const c = withEnv({ STILLFAIL_DELTA_FAST_FORCE: undefined, STILLFAIL_DELTA_JS: undefined }, () => time(() => makeDelta(old, made, [], [], [])));
  assert.equal(delta.lastMaker, "native");
  const js = inJs(() => time(() => makeDelta(old, made, [], [], [])));
  t.diagnostic(`C ${c.d.length} bytes in ${c.ms.toFixed(0)} ms, JavaScript ${js.d.length} bytes in ${js.ms.toFixed(0)} ms`);
  gives(c.d, old, made);
  assert.ok(records(c.d).equals(records(js.d)), "the same records");
  assert.ok(Math.abs(c.d.length - js.d.length) <= js.d.length * 0.05 + 1024, `${c.d.length} bytes against ${js.d.length}`);
});

test("delta-fast --verify matches unverified output byte for byte, and makeTreeFromBuffer matches JS path", { skip }, (t) => {
  const dir = mkdtempSync(join(tmpdir(), "delta-fast-verify-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const bin = native!;
  const rand = prng(5150);
  const files: Record<string, Buffer> = {
    "a/bin": texty(rand, 160_000),
    "b/lib": random(rand, 50_000),
    "c/cfg": Buffer.from("config-v1\n".repeat(400)),
  };
  for (const [p, b] of Object.entries(files)) {
    mkdirSync(dirname(join(dir, "old", p)), { recursive: true });
    writeFileSync(join(dir, "old", p), b);
  }
  const ordered = Object.keys(files).sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b)));
  const bufs = ordered.map((k) => files[k]!);
  const ranges: Range[] = [];
  for (let at = 0, i = 0; i < bufs.length; at += bufs[i]!.length, i++) ranges.push({ at, len: bufs[i]!.length });
  const oldBlob = Buffer.concat(bufs);
  const madeBlob = Buffer.concat([files["c/cfg"]!, edited(rand, files["a/bin"]!, 4096), random(rand, 1024), files["b/lib"]!]);

  const oldPath = join(dir, "old.blob"), madePath = join(dir, "made.blob");
  const filesPath = join(dir, "files.bin"), runsPath = join(dir, "runs.bin");
  writeFileSync(oldPath, oldBlob);
  writeFileSync(madePath, madeBlob);
  const filesBin = Buffer.alloc(ranges.length * 8);
  ranges.forEach((f, i) => { filesBin.writeUInt32LE(f.at, i * 8); filesBin.writeUInt32LE(f.len, i * 8 + 4); });
  writeFileSync(filesPath, filesBin);
  const runs = sameBlocks(oldBlob, madeBlob, wholeFiles(oldBlob, ranges, madeBlob));
  const runsBin = Buffer.alloc(runs.length * 12);
  runs.forEach((r, i) => { runsBin.writeUInt32LE(r.made, i * 12); runsBin.writeUInt32LE(r.old, i * 12 + 4); runsBin.writeUInt32LE(r.len, i * 12 + 8); });
  writeFileSync(runsPath, runsBin);

  // 1) --files --verify vs --files, and --verify (4-arg) vs 4-arg
  const outFiles = join(dir, "out-files"), outFilesVerify = join(dir, "out-files-verify");
  const out4 = join(dir, "out-4"), out4Verify = join(dir, "out-4-verify");
  execFileSync(bin, ["--files", oldPath, madePath, filesPath, outFiles], { stdio: ["ignore", "ignore", "pipe"] });
  execFileSync(bin, ["--files", "--verify", oldPath, madePath, filesPath, outFilesVerify], { stdio: ["ignore", "ignore", "pipe"] });
  execFileSync(bin, [oldPath, madePath, runsPath, out4], { stdio: ["ignore", "ignore", "pipe"] });
  execFileSync(bin, ["--verify", oldPath, madePath, runsPath, out4Verify], { stdio: ["ignore", "ignore", "pipe"] });
  assert.ok(readFileSync(outFilesVerify).equals(readFileSync(outFiles)), "--files --verify matches --files byte for byte");
  assert.ok(readFileSync(out4Verify).equals(readFileSync(out4)), "--verify matches 4-arg byte for byte");

  // 2) makeTreeFromBuffer: native --verify path vs JS path
  const dNativePath = join(dir, "native.delta"), dJsPath = join(dir, "js.delta");
  inC(() => makeTreeFromBuffer(ordered, ranges, oldBlob, madePath, dNativePath));
  inJs(() => makeTreeFromBuffer(ordered, ranges, oldBlob, madePath, dJsPath));
  const dNative = readFileSync(dNativePath), dJs = readFileSync(dJsPath);
  assert.deepEqual(parseHeader(dNative), parseHeader(dJs), "headers match");
  assert.ok(records(dNative).equals(records(dJs)), "native and JS bsdiff records match byte for byte");
  // Independent applyFile verification on both
  const outNative = join(dir, "applied-native"), outJs = join(dir, "applied-js");
  applyFile({ dir: join(dir, "old") }, dNativePath, outNative);
  applyFile({ dir: join(dir, "old") }, dJsPath, outJs);
  assert.ok(readFileSync(outNative).equals(madeBlob), "applyFile restores made from native delta");
  assert.ok(readFileSync(outJs).equals(madeBlob), "applyFile restores made from JS delta");
});

test("delta-fast --check-only adversarial and boundary verification", { skip }, (t) => {
  const dir = mkdtempSync(join(tmpdir(), "delta-fast-check-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const bin = native!;

  const packChunks = (raw: Buffer, cut = CHUNK) => {
    const parts: Buffer[] = [];
    for (let at = 0; at < raw.length; at += cut) {
      const piece = raw.subarray(at, at + cut);
      const packed = deflateRawSync(piece, { level: 6 });
      const head = Buffer.alloc(8);
      head.writeUInt32LE(piece.length, 0);
      head.writeUInt32LE(packed.length, 4);
      parts.push(head, packed);
    }
    return Buffer.concat(parts);
  };
  const rec = (x: bigint, y: bigint, z: bigint, ...payload: Buffer[]) => {
    const b = Buffer.alloc(24);
    b.writeBigInt64LE(x, 0);
    b.writeBigInt64LE(y, 8);
    b.writeBigInt64LE(z, 16);
    return Buffer.concat([b, ...payload]);
  };
  const check = (old: Buffer, made: Buffer, chunks: Buffer, name: string) => {
    const op = join(dir, `${name}.old`), mp = join(dir, `${name}.made`), cp = join(dir, `${name}.chunks`);
    writeFileSync(op, old);
    writeFileSync(mp, made);
    writeFileSync(cp, chunks);
    const res = spawnSync(bin, ["--check-only", op, mp, cp], { encoding: "utf8" });
    return { status: res.status, stderr: res.stderr, chunksPath: cp };
  };

  // Valid baseline: old = "abcdef", made = "bcdfXY" (diff 3 bytes +1, extra 2 bytes "XY", plus 1 byte past old? No, diff 4 bytes + extra 2)
  const oldSmall = Buffer.from("abcdef");
  const madeSmall = Buffer.from("bcdeXY");
  const goodRaw = rec(4n, 2n, 0n, Buffer.from([1, 1, 1, 1]), Buffer.from("XY"));
  const goodChunks = packChunks(goodRaw);
  assert.equal(check(oldSmall, madeSmall, goodChunks, "good").status, 0);
  // Record spanning tiny chunks (cut = 7 bytes)
  assert.equal(check(oldSmall, madeSmall, packChunks(goodRaw, 7), "span-small").status, 0);
  // Out-of-bounds old read (treated as 0, matching station/src/updates/delta.ts)
  const oobMade = Buffer.from("abcdef\x00\x07");
  assert.equal(check(oldSmall, oobMade, packChunks(rec(8n, 0n, 0n, Buffer.from([0, 0, 0, 0, 0, 0, 0, 7]))), "oob-old").status, 0);

  // 1) Flip 1 bit in diff byte -> must fail and NOT delete chunks file
  const badDiffRaw = Buffer.from(goodRaw);
  badDiffRaw[25] = badDiffRaw[25]! ^ 0x01;
  const rDiff = check(oldSmall, madeSmall, packChunks(badDiffRaw), "bad-diff");
  assert.notEqual(rDiff.status, 0, "1-bit diff flip must fail");
  assert.equal(existsSync(rDiff.chunksPath), true, "--check-only must not unlink chunks on failure");

  // 2) Flip 1 bit in extra byte -> must fail
  const badExtraRaw = Buffer.from(goodRaw);
  badExtraRaw[29] = badExtraRaw[29]! ^ 0x01;
  assert.notEqual(check(oldSmall, madeSmall, packChunks(badExtraRaw), "bad-extra").status, 0, "1-bit extra flip must fail");

  // 3) Truncated chunk / corrupted deflate stream / wrong raw_len
  assert.notEqual(check(oldSmall, madeSmall, goodChunks.subarray(0, goodChunks.length - 1), "trunc-payload").status, 0, "truncated payload must fail");
  assert.notEqual(check(oldSmall, madeSmall, goodChunks.subarray(0, 5), "trunc-header").status, 0, "truncated chunk header must fail");
  const corruptDeflate = Buffer.from(goodChunks);
  corruptDeflate[corruptDeflate.length - 1] = corruptDeflate[corruptDeflate.length - 1]! ^ 0xff;
  assert.notEqual(check(oldSmall, madeSmall, corruptDeflate, "corrupt-deflate").status, 0, "corrupted deflate must fail");
  const badRawLen = Buffer.from(goodChunks);
  badRawLen.writeUInt32LE(goodRaw.length + 1, 0);
  assert.notEqual(check(oldSmall, madeSmall, badRawLen, "wrong-raw-len").status, 0, "raw_len mismatch must fail");
  const zeroRawLen = Buffer.from(goodChunks);
  zeroRawLen.writeUInt32LE(0, 0);
  assert.notEqual(check(oldSmall, madeSmall, zeroRawLen, "zero-raw-len").status, 0, "raw_len == 0 must fail");
  const hugeRawLen = Buffer.from(goodChunks);
  hugeRawLen.writeUInt32LE(CHUNK + 1, 0);
  assert.notEqual(check(oldSmall, madeSmall, hugeRawLen, "huge-raw-len").status, 0, "raw_len > CHUNK must fail");

  // 4) Trailing garbage bytes / extra chunk / leftover bytes in same chunk
  assert.notEqual(check(oldSmall, madeSmall, Buffer.concat([goodChunks, Buffer.from([0])]), "trailing-1b").status, 0, "trailing byte must fail");
  assert.notEqual(check(oldSmall, madeSmall, Buffer.concat([goodChunks, Buffer.alloc(8)]), "trailing-end-chunk").status, 0, "trailing end chunk must fail");
  assert.notEqual(check(oldSmall, madeSmall, Buffer.concat([goodChunks, packChunks(rec(0n, 0n, 0n))]), "extra-chunk").status, 0, "extra chunk must fail");
  assert.notEqual(check(oldSmall, madeSmall, packChunks(Buffer.concat([goodRaw, Buffer.from([0])])), "trailing-in-chunk").status, 0, "trailing byte inside chunk must fail");

  // 5) Malformed control records: negative x, negative y, x+y out of bounds, i64 overflow (> 2^53-1 or < -2^53), early EOF
  assert.notEqual(check(oldSmall, madeSmall, packChunks(rec(-1n, 6n, 0n, madeSmall)), "neg-x").status, 0, "negative x must fail");
  assert.notEqual(check(oldSmall, madeSmall, packChunks(rec(0n, -1n, 0n)), "neg-y").status, 0, "negative y must fail");
  assert.notEqual(check(oldSmall, madeSmall, packChunks(rec(4n, 3n, 0n, Buffer.from([1, 1, 1, 1]), Buffer.from("XYZ"))), "oob-xy").status, 0, "x+y > madeSize must fail");
  assert.notEqual(check(oldSmall, madeSmall, packChunks(rec(1n << 53n, 0n, 0n)), "i64-hi-pos").status, 0, "x >= 2^53 must fail");
  assert.notEqual(check(oldSmall, madeSmall, packChunks(rec(0n, 0n, -(1n << 53n) - 1n)), "i64-hi-neg").status, 0, "z < -2^53 must fail");
  assert.notEqual(check(oldSmall, madeSmall, packChunks(rec(3n, 2n, 0n, Buffer.from([1, 1, 1]), Buffer.from("XY"))), "early-eof").status, 0, "stream ending before madeSize must fail");

  // 6) 0-byte made file: empty chunks passes, non-empty chunks rejected
  assert.equal(check(oldSmall, Buffer.alloc(0), Buffer.alloc(0), "empty-ok").status, 0, "0-byte made with empty chunks must pass");
  assert.notEqual(check(oldSmall, Buffer.alloc(0), goodChunks, "empty-nonempty").status, 0, "0-byte made with non-empty chunks must fail");
  assert.notEqual(check(oldSmall, Buffer.alloc(0), Buffer.alloc(8), "empty-8zero").status, 0, "0-byte made with 8 zero bytes must fail");

  // 7) Record spanning > 1 MiB chunk boundary (> 1.5 MiB blob) passes
  const rand = prng(7777);
  const bigOld = texty(rand, 1_600_000);
  const bigMade = Buffer.concat([edited(rand, bigOld, 10_000), random(rand, 200_000)]);
  const bigOldPath = join(dir, "big.old"), bigMadePath = join(dir, "big.made");
  const bigFilesPath = join(dir, "big.files"), bigChunksPath = join(dir, "big.chunks");
  writeFileSync(bigOldPath, bigOld);
  writeFileSync(bigMadePath, bigMade);
  writeFileSync(bigFilesPath, Buffer.alloc(0));
  execFileSync(bin, ["--files", "--verify", bigOldPath, bigMadePath, bigFilesPath, bigChunksPath], { stdio: ["ignore", "ignore", "pipe"] });
  const bigCheck = spawnSync(bin, ["--check-only", bigOldPath, bigMadePath, bigChunksPath], { encoding: "utf8" });
  assert.equal(bigCheck.status, 0, `>1.5 MiB cross-chunk check failed: ${bigCheck.stderr}`);
});

/** A zip as a minimal writer makes one (node's deflate, level 6: what the delta's check makes again). */
function zip(entries: [string, Buffer, boolean][]): Buffer {
  const locals: Buffer[] = [], central: Buffer[] = [];
  let offset = 0;
  for (const [n, data, deflate] of entries) {
    const name = Buffer.from(n), body = deflate ? deflateRawSync(data, { level: 6 }) : data;
    const fields = (h: Buffer, at: number) => {
      h.writeUInt16LE(deflate ? 8 : 0, at);
      h.writeUInt32LE(crc32(data), at + 6);
      h.writeUInt32LE(body.length, at + 10);
      h.writeUInt32LE(data.length, at + 14);
      h.writeUInt16LE(name.length, at + 18);
    };
    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(20, 4);
    fields(local, 8);
    const c = Buffer.alloc(46);
    c.writeUInt32LE(0x02014b50, 0);
    c.writeUInt16LE(20, 4);
    c.writeUInt16LE(20, 6);
    fields(c, 10);
    c.writeUInt32LE(offset, 42);
    locals.push(local, name, body);
    central.push(c, name);
    offset += 30 + name.length + body.length;
  }
  const cd = Buffer.concat(central), end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0);
  end.writeUInt16LE(entries.length, 8);
  end.writeUInt16LE(entries.length, 10);
  end.writeUInt32LE(cd.length, 12);
  end.writeUInt32LE(offset, 16);
  return Buffer.concat([...locals, cd, end]);
}
