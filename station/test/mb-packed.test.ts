// Transcripts put away by the MoonBit program (`--builder packed`, station/mb src/packed and the shell's `zstd.segments`,
// `zstd.check`; the station's sessions/packed-mb.ts for sessions/archive.ts) held to the TypeScript it replaced
// (test/reference/packed.ts, and its `segmentedBytes` for what archive.ts made before): the same table byte for byte,
// the same frames read of a file, the same answer to whether one is in segments, the same cuts between segments, and
// what each puts away read by the other, whole, a page at a time, or not at all where a byte of it is lost.
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { closeSync, existsSync, mkdtempSync, openSync, readFileSync, rmSync, statSync, truncateSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";
import { constants, zstdCompressSync } from "node:zlib";
import { mbReaderBinary } from "../src/read/mb-reader.ts";
import { packFile, packFileIf, restoreFile, segmentFile } from "../src/sessions/archive.ts";
import { IDLE_MS, PackedProgram } from "../src/sessions/packed-mb.ts";
import { SEGMENT, framesOf, readSegments, seekTable, segmented, segmentedBytes, segmentedSoon, segmentsFrom, unpackedWhole } from "./reference/packed.ts";

const binary = mbReaderBinary();
const skip = binary === null ? "the MoonBit program (stillfail-reader) is not built here" : false;

const dirs: string[] = [];
let program: PackedProgram | null = null;
after(async () => {
  await program?.close();
  for (const d of dirs) rmSync(d, { recursive: true, force: true });
});
const fresh = () => {
  const dir = mkdtempSync(join(tmpdir(), "mb-packed-"));
  dirs.push(dir);
  return dir;
};
const mb = () => (program ??= new PackedProgram({ binary: binary! }));

const sha = (b: Buffer) => createHash("sha256").update(b).digest("hex");
const framesFile = (path: string) => {
  const file = openSync(path, "r");
  try {
    return framesOf(file);
  } finally {
    closeSync(file);
  }
};
/// What a put-away transcript holds, read by each of the reference's readers: whole, from its start a segment at a
/// time, and in pages across its segments' ends.
async function readEveryWay(path: string): Promise<Buffer> {
  const whole = unpackedWhole(path);
  const streamed: Buffer[] = [];
  const segments = await segmentsFrom(path, 0);
  assert.ok(segments, "a table");
  for await (const piece of segments) streamed.push(piece);
  assert.deepEqual(Buffer.concat(streamed), whole, "streamed as read whole");
  const size = whole.length;
  for (const [from, end] of [[0, size], [Math.floor(size / 3), Math.floor(size / 3) + 1000], [Math.max(0, size - 7), size]] as const) {
    const pieces: Buffer[] = [];
    assert.ok(readSegments(path, from, end, (p) => (pieces.push(Buffer.from(p)), true)));
    assert.deepEqual(Buffer.concat(pieces), whole.subarray(from, end), `${from}..${end}`);
  }
  return whole;
}

/// Lines of every length from a seed: some UTF-8 of every width, some binary (no line ends inside), one longer than a
/// segment where `long`.
function linesOf(seed: number, bytes: number, long = false): Buffer {
  let a = seed >>> 0;
  const r = () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = Math.imul(a ^ (a >>> 15), a | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
  const parts: Buffer[] = [];
  let n = 0;
  for (let i = 0; n < bytes; i++) {
    const kind = r();
    const length = Math.floor(r() * 300_000);
    const part = long && i === 3
      ? Buffer.alloc(SEGMENT + 333, 0x4c)
      : kind < 0.3
        ? Buffer.from("é中😀".repeat(Math.ceil(length / 9)).slice(0, Math.ceil(length / 3)))
        : kind < 0.5
          ? Buffer.from(Array.from({ length: Math.min(length, 4096) }, (_, k) => (k * 131 + i) % 256).filter((b) => b !== 0x0a))
          : Buffer.from(JSON.stringify({ i, said: "y".repeat(length) }));
    parts.push(part, Buffer.from("\n"));
    n += part.length + 1;
  }
  return Buffer.concat(parts).subarray(0, bytes);
}

test("the table is the reference's byte for byte, and a file's frames are read as it reads them", { skip }, async () => {
  const lists: { packed: number; size: number }[][] = [[], [{ packed: 9, size: 0 }], [{ packed: 0xffffffff, size: 0 }, { packed: 1, size: 0xfffffffe }]];
  for (let i = 1; i < 40; i++) lists.push(Array.from({ length: i % 7 }, (_, k) => ({ packed: (i * 7919 + k * 104729) % 2 ** 32, size: (i * k * 15485863) % 2 ** 32 })));
  for (const frames of lists) {
    const { table } = await mb().ask("table", { frames: frames.map((f) => [f.packed, f.size]) });
    assert.equal(table, seekTable(frames).toString("hex"));
  }
  const dir = fresh();
  const at = (name: string, bytes: Buffer) => (writeFileSync(join(dir, name), bytes), join(dir, name));
  const made = segmentedBytes(linesOf(1, SEGMENT * 2 + 999));
  const table = seekTable([{ packed: 5, size: 3 }]);
  const files = [
    at("segmented.zst", made),
    at("whole.zst", zstdCompressSync(Buffer.from("no table\n"))),
    at("empty.zst", Buffer.alloc(0)),
    at("short.zst", table.subarray(0, 16)),
    at("table-only.zst", seekTable([])),
    at("off-by-one.zst", Buffer.concat([Buffer.alloc(4), table])),
    at("adds-up.zst", Buffer.concat([Buffer.alloc(5), table])),
    at("cut.zst", made.subarray(0, made.length - 1)),
    at("checksums.zst", Buffer.concat([Buffer.alloc(5), (() => { const t = Buffer.alloc(8 + 12 + 9); t.writeUInt32LE(0x184d2a5e, 0); t.writeUInt32LE(t.length - 8, 4); t.writeUInt32LE(5, 8); t.writeUInt32LE(3, 12); t.writeUInt32LE(1, 20); t[24] = 0x80; t.writeUInt32LE(0x8f92eab1, 25); return t; })()])),
    at("reserved.zst", (() => { const t = Buffer.from(table); t[t.length - 5] = 0x01; return Buffer.concat([Buffer.alloc(5), t]); })()),
  ];
  for (const path of files) {
    const { frames } = await mb().ask("frames", { path });
    const theirs = framesFile(path);
    assert.deepEqual(frames, theirs === null ? null : theirs.map((f) => [f.at, f.packed, f.from, f.size]), path);
    assert.equal((await mb().ask("segmented", { path })).segmented, segmented(path), path);
    assert.equal(segmented(path), await segmentedSoon(path), path);
  }
  assert.equal((await mb().ask("segmented", { path: join(dir, "none.zst") })).segmented, false);
  await assert.rejects(mb().ask("frames", { path: join(dir, "none.zst") }));
});

test("a transcript is cut where the reference cut it: at a segment's last line's end, at SEGMENT in a longer line, the last never empty", { skip }, async () => {
  const dir = fresh();
  const line = (n: number) => Buffer.concat([Buffer.alloc(n - 1, 0x7a), Buffer.from("\n")]);
  const cases: [string, Buffer][] = [
    ["empty", Buffer.alloc(0)],
    ["one byte", Buffer.from("x")],
    ["exactly a segment, ending a line", Buffer.concat([line(SEGMENT - 1000), line(1000)])],
    ["exactly a segment, no line end", Buffer.alloc(SEGMENT, 0x61)],
    ["a byte more, its line ending before", Buffer.concat([line(SEGMENT - 10), Buffer.alloc(11, 0x62)])],
    ["a byte more, its last byte a line end", Buffer.concat([Buffer.alloc(SEGMENT, 0x63), Buffer.from("\n")])],
    ["a line end at the segment's last byte, more after", Buffer.concat([line(SEGMENT), Buffer.from("tail")])],
    ["no line end at all", Buffer.alloc(SEGMENT * 2 + 5, 0x64)],
    ["lines of every length, one longer than a segment", linesOf(7, SEGMENT * 3 + 777, true)],
    ["UTF-8 and binary lines", linesOf(11, SEGMENT + 12345)],
  ];
  for (const [what, content] of cases) {
    const path = join(dir, "t.jsonl");
    writeFileSync(path, content);
    await packFile(path);
    assert.equal(existsSync(path), false, what);
    const mine = framesFile(`${path}.zst`)!;
    const before = segmentedBytes(content);
    const reference = join(dir, "reference.zst");
    writeFileSync(reference, before);
    assert.deepEqual(mine.map((f) => [f.from, f.size]), framesFile(reference)!.map((f) => [f.from, f.size]), what);
    assert.ok(mine.slice(0, -1).every((f) => f.size > 0 && f.size <= SEGMENT), what);
    // Every segment compressed, with its checksum; read by the reference every way it reads, as it was.
    assert.ok(segmented(`${path}.zst`), what);
    const head = readFileSync(`${path}.zst`).subarray(mine.at(-1)!.at, mine.at(-1)!.at + 5);
    assert.ok((head[4]! & 4) !== 0, `${what}: checksummed`);
    assert.equal(sha(await readEveryWay(`${path}.zst`)), sha(content), what);
    // 0600, as the Rust station's.
    if (process.platform !== "win32") assert.equal(statSync(`${path}.zst`).mode & 0o777, 0o600, what);
    // Written back whole, as it was.
    await restoreFile(path);
    assert.equal(sha(readFileSync(path)), sha(content), what);
    assert.equal(existsSync(`${path}.zst`), false, what);
    rmSync(path);
  }
});

test("what was put away before (one frame, several, a segment stored as it is, the archive's own of before) is put away again and written back", { skip }, async () => {
  const dir = fresh();
  const content = linesOf(3, SEGMENT + 54321);
  const half = content.length >> 1;
  const stored = (() => {
    const text = Buffer.from(`${"z".repeat(1023)}\n`.repeat(64));
    const head = Buffer.alloc(13);
    head.writeUInt32LE(0xfd2fb528, 0);
    head[4] = 0xe0;
    head.writeBigUInt64LE(BigInt(text.length), 5);
    const word = (text.length << 3) | 1;
    const frame = Buffer.concat([head, Buffer.from([word & 0xff, (word >> 8) & 0xff, (word >> 16) & 0xff]), text]);
    return { text, file: Buffer.concat([frame, seekTable([{ packed: frame.length, size: text.length }])]) };
  })();
  const checked = { params: { [constants.ZSTD_c_checksumFlag]: 1 } };
  const olds: [string, Buffer, Buffer, boolean][] = [
    ["one frame, no table", zstdCompressSync(content), content, true],
    ["one frame with a checksum", zstdCompressSync(content, checked), content, true],
    ["two frames, no table", Buffer.concat([zstdCompressSync(content.subarray(0, half)), zstdCompressSync(content.subarray(half))]), content, true],
    ["a segment stored as it is", stored.file, stored.text, true],
    ["in segments already", segmentedBytes(content), content, false],
  ];
  for (const [what, file, holds, again] of olds) {
    const path = join(dir, "t.jsonl");
    writeFileSync(`${path}.zst`, file);
    assert.equal(await segmentFile(path), again, what);
    assert.ok(segmented(`${path}.zst`), what);
    assert.equal(sha(await readEveryWay(`${path}.zst`)), sha(holds), what);
    assert.equal(await segmentFile(path), false, `${what}: once`);
    assert.equal(existsSync(`${path}.zst.writing`), false, what);
    // And one put away so, written back.
    writeFileSync(`${path}.zst`, file);
    await restoreFile(path);
    assert.equal(sha(readFileSync(path)), sha(holds), what);
    rmSync(path);
  }
});

test("a put-away transcript a byte short is never taken as whole: not written back, not put away again, its copy kept", { skip }, async () => {
  const dir = fresh();
  const content = linesOf(5, SEGMENT + 999);
  const whole = segmentedBytes(content);
  const one = zstdCompressSync(Buffer.from("the only copy of this history\n"), { params: { [constants.ZSTD_c_checksumFlag]: 1 } });
  const cuts: [string, Buffer][] = [
    ["the table's last byte", whole.subarray(0, whole.length - 1)],
    ["a frame's checksum's last byte", Buffer.concat([one.subarray(0, one.length - 1), seekTable([{ packed: one.length - 1, size: 30 }])])],
    ["one frame without a table", one.subarray(0, one.length - 1)],
    ["the old stored segment's last byte", (() => { const f = Buffer.concat([Buffer.from([0x28, 0xb5, 0x2f, 0xfd, 0xe0]), Buffer.alloc(8), Buffer.from([0x29, 0, 0]), Buffer.from("abcd")]); f.writeBigUInt64LE(5n, 5); return f; })()],
  ];
  for (const [what, file] of cuts) {
    const path = join(dir, "t.jsonl");
    writeFileSync(`${path}.zst`, file);
    await assert.rejects(restoreFile(path), what);
    assert.equal(existsSync(path), false, what);
    assert.deepEqual(readFileSync(`${path}.zst`), file, what);
    // (one in segments, its table adding up, is not looked into again: as the reference's `segmentedSoon` says)
    if (segmented(`${path}.zst`)) assert.equal(await segmentFile(path), false, what);
    else await assert.rejects(segmentFile(path), what);
    assert.deepEqual(readFileSync(`${path}.zst`), file, what);
    // Where only the copy is left, packing again reads it through and fails.
    await assert.rejects(packFile(path), what);
    assert.equal(existsSync(`${path}.zst.writing`), false, what);
    assert.equal(existsSync(`${path}.jsonl.restoring`), false, what);
  }
  // Whole, it is read through.
  const path = join(dir, "t.jsonl");
  writeFileSync(`${path}.zst`, whole);
  await packFile(path);
  // A transcript that is not ready to go is not put away; its copy goes with it.
  writeFileSync(path, content);
  rmSync(`${path}.zst`);
  await packFileIf(path, () => false);
  assert.deepEqual(readFileSync(path), content);
  assert.equal(existsSync(`${path}.zst`), false);
  assert.equal(existsSync(`${path}.zst.writing`), false);
  truncateSync(path, 0);
});

test("the program is let go once nothing was asked of it for IDLE_MS, and started again by the next ask", { skip }, async () => {
  let fire: (() => void) | null = null;
  let armed = 0;
  const p = new PackedProgram({
    binary: binary!,
    after: (ms, f) => {
      assert.equal(ms, IDLE_MS);
      armed++;
      fire = f;
      return () => (fire = null);
    },
  });
  try {
    assert.equal((await p.ask("table", { frames: [] })).table, seekTable([]).toString("hex"));
    assert.equal(p.running, true);
    assert.equal(armed, 1);
    fire!();
    assert.equal(p.running, false);
    assert.equal((await p.ask("segmented", { path: join(fresh(), "none") })).segmented, false);
    assert.equal(p.started, 2);
    assert.equal(p.trimIdle(), 1);
    assert.equal(p.running, false);
  } finally {
    await p.close();
  }
});
