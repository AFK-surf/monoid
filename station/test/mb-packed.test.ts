// Transcripts put away by the MoonBit program (`--builder packed`, station/mb src/packed and the shell's `zstd.segments`,
// `zstd.check`; the station's sessions/packed-mb.ts for sessions/archive.ts) held to the TypeScript it replaced
// (test/reference/packed.ts, and its `segmentedBytes` for what archive.ts made before): the same table byte for byte,
// the same frames read of a file, the same answer to whether one is in segments, the same cuts between segments, and
// what each puts away read by the other, whole, a page at a time, or not at all where a byte of it is lost. And a
// workspace's tar (the shell's `tar.pack`, `tar.unpack`, `tar.file`) held to the TypeScript that wrote and read it before
// (test/reference/workspace-archive.ts): the same tar byte for byte, and what either packed restored and read by the
// other, an archive cut short or leading out of its workspace refused by both.
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import {
  chmodSync,
  closeSync,
  existsSync,
  linkSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  openSync,
  readFileSync,
  readdirSync,
  readlinkSync,
  realpathSync,
  rmSync,
  statSync,
  symlinkSync,
  truncateSync,
  utimesSync,
  writeFileSync,
} from "node:fs";
import { createServer, type Server } from "node:net";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { after, test } from "node:test";
import { constants, zstdCompressSync, zstdDecompressSync } from "node:zlib";
import { mbReaderBinary } from "../src/read/mb-reader.ts";
import {
  emptyWorkspace,
  packFile,
  packFileIf,
  packWorkspace,
  restoreFile,
  restoreWorkspace,
  segmentFile,
  workspaceArchive,
  workspaceFile,
} from "../src/sessions/archive.ts";
import { IDLE_MS, PackedProgram } from "../src/sessions/packed-mb.ts";
import { checksum, fileOf, gnuHeader, numberInto, packTree, padding, tarOfHeaders, unpackArchive } from "./reference/workspace-archive.ts";
import { SEGMENT, framesOf, readSegments, seekTable, segmented, segmentedBytes, segmentedSoon, segmentsFrom, unpackedWhole } from "./reference/packed.ts";

const binary = mbReaderBinary();
const skip = binary === null ? "the MoonBit program (stillfail-reader) is not built here" : false;

const dirs: string[] = [];
let program: PackedProgram | null = null;
after(async () => {
  await program?.close();
  for (const d of dirs) {
    // (a read-only directory a workspace's test left, where it failed before it made it writable again)
    if (process.platform !== "win32" && existsSync(d)) execFileSync("chmod", ["-R", "u+rwx", d]);
    rmSync(d, { recursive: true, force: true });
  }
});
const fresh = () => {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), "mb-packed-")));
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

// ── workspaces: the shell's tar (`tar.pack`, `tar.unpack`, `tar.file`) and the TypeScript it replaced ──

/// Everything under `dir` as a line each: its kind, mode, and contents (a file's hash and mtime, a link's target).
function manifest(dir: string, rel = ""): string[] {
  const out: string[] = [];
  for (const name of readdirSync(join(dir, rel)).sort()) {
    const path = join(dir, rel, name);
    const r = rel === "" ? name : `${rel}/${name}`;
    const meta = lstatSync(path);
    if (meta.isSymbolicLink()) out.push(`${r} link ${readlinkSync(path)}`);
    else if (meta.isDirectory()) {
      out.push(`${r} dir ${(meta.mode & 0o7777).toString(8)}`);
      out.push(...manifest(dir, r));
    } else if (meta.isFIFO()) out.push(`${r} fifo ${(meta.mode & 0o7777).toString(8)}`);
    else if (meta.isSocket()) out.push(`${r} socket`);
    else out.push(`${r} file ${(meta.mode & 0o7777).toString(8)} ${meta.size} ${sha(readFileSync(path)).slice(0, 16)} ${Math.floor(meta.mtimeMs / 1000)}`);
  }
  return out;
}

const put = (path: string, bytes: string | Buffer) => {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, bytes);
};
const UPLOAD = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0, 1, 2, 3]);
const DEEP = `${"长路径-".repeat(12)}/${"名字".repeat(30)}.md`;

/// A workspace with what people's have: long and non-ASCII names (past a header's 100 bytes), a long link and a
/// dangling one, a hard link, a read-only directory, empty files and directories, a big file, a pipe, an upload.
function fillWorkspace(ws: string) {
  put(join(ws, "project/src/main.rs"), "fn main() {}\n");
  put(join(ws, "script.sh"), "#!/bin/sh\ntrue\n");
  chmodSync(join(ws, "script.sh"), 0o751);
  put(join(ws, "uploads/截图 1.png"), UPLOAD);
  put(join(ws, DEEP), "deep and long");
  put(join(ws, "empty"), "");
  mkdirSync(join(ws, "an/empty/dir"), { recursive: true });
  put(join(ws, "random.bin"), Buffer.from(Array.from({ length: 3 << 20 }, (_, i) => (i * 2654435761) >>> 24)));
  symlinkSync(`${"远处/".repeat(30)}target`, join(ws, "long-link"));
  symlinkSync("/nonexistent/absolute", join(ws, "dangling"));
  put(join(ws, "a"), "hard linked");
  linkSync(join(ws, "a"), join(ws, "b"));
  put(join(ws, "readonly/go.mod"), "module m");
  chmodSync(join(ws, "readonly"), 0o500);
  execFileSync("mkfifo", ["-m", "640", join(ws, "pipe")]);
  utimesSync(join(ws, "project/src/main.rs"), 1_700_000_000, 1_700_000_000);
}

const unixOnly = skip || (process.platform === "win32" && "pipes, modes and links are Unix's");

test("a workspace the shell packs is the tar the reference packed, byte for byte, and each restores what the other packed", { skip: unixOnly }, async () => {
  const dir = fresh();
  const room = join(dir, "room");
  const ws = join(room, "workspace");
  fillWorkspace(ws);
  const before = manifest(ws);
  // The reference's archive of the same tree, beside it: the same tar.
  const theirs = join(dir, "reference.tar.zst");
  await packTree(ws, theirs);
  await packWorkspace(room);
  const mine = workspaceArchive(room);
  assert.deepEqual(readdirSync(ws), [], "the originals go once packed");
  assert.equal(statSync(mine).mode & 0o777, 0o600);
  assert.deepEqual(zstdDecompressSync(readFileSync(mine)), zstdDecompressSync(readFileSync(theirs)), "the same tar");
  // What the shell packed, the reference unpacks as it was, and reads a file of.
  const out = join(dir, "by-reference");
  mkdirSync(out);
  assert.deepEqual(await unpackArchive(mine, out), new Map());
  assert.deepEqual(manifest(out), before);
  assert.deepEqual(await fileOf(mine, ["uploads", "截图 1.png"]), UPLOAD);
  // And the shell reads it: a file by its path (with `./`, with Windows' separators), none for a directory or what is
  // not there, nothing left beside the archive.
  assert.deepEqual(await workspaceFile(room, "uploads/截图 1.png"), UPLOAD);
  assert.deepEqual(await workspaceFile(room, `./${DEEP}`), Buffer.from("deep and long"));
  if (process.platform === "win32") assert.deepEqual(await workspaceFile(room, "uploads\\截图 1.png"), UPLOAD);
  assert.equal(await workspaceFile(room, "an"), null);
  assert.equal(await workspaceFile(room, "missing"), null);
  assert.deepEqual(readdirSync(room).filter((n) => n.includes("reading")), []);
  // What the reference packed, the shell restores as it was.
  writeFileSync(mine, readFileSync(theirs));
  put(join(ws, "uploads/new.txt"), "new while archived");
  // (what a read left as its process ended goes with the archive)
  writeFileSync(`${mine}.reading-7`, "left");
  await restoreWorkspace(room);
  assert.equal(existsSync(mine), false);
  assert.deepEqual(readdirSync(room).filter((n) => n.includes("reading")), []);
  assert.deepEqual(manifest(ws).filter((l) => !l.startsWith("uploads")), before.filter((l) => !l.startsWith("uploads")));
  assert.equal(readFileSync(join(ws, "uploads/new.txt"), "utf8"), "new while archived");
  assert.deepEqual(readFileSync(join(ws, "uploads/截图 1.png")), UPLOAD);
  // And empties it, its uploads out of the archive the reference made.
  await packTree(ws, mine);
  writeFileSync(`${mine}.reading-8`, "left");
  await emptyWorkspace(room);
  assert.deepEqual(readdirSync(room).filter((n) => n.includes("reading")), []);
  assert.deepEqual(readdirSync(ws), ["uploads"]);
  assert.deepEqual(readdirSync(join(ws, "uploads")).sort(), ["new.txt", "截图 1.png"]);
  assert.deepEqual(readFileSync(join(ws, "uploads/截图 1.png")), UPLOAD);
  assert.equal(existsSync(mine), false);
});

test("a workspace's Unix sockets are left out by the shell as by the reference, and one made since does not stop its restore", { skip: unixOnly }, async () => {
  const dir = fresh();
  const room = join(dir, "room");
  const ws = join(room, "workspace");
  put(join(ws, "a.txt"), "kept");
  put(join(ws, "sub/b.txt"), "kept too");
  const servers: Server[] = [];
  const listen = async (path: string) => {
    const server = createServer();
    servers.push(server);
    await new Promise<void>((done, failed) => server.once("error", failed).listen(path, done));
  };
  try {
    await listen(join(ws, "node-3.sock"));
    await listen(join(ws, "sub/n.sock"));
    const before = manifest(ws).filter((l) => !l.endsWith(" socket"));
    assert.equal(manifest(ws).length - before.length, 2);
    const theirs = join(dir, "reference.tar.zst");
    await packTree(ws, theirs);
    await packWorkspace(room);
    const mine = workspaceArchive(room);
    assert.deepEqual(zstdDecompressSync(readFileSync(mine)), zstdDecompressSync(readFileSync(theirs)), "the same tar");
    const out = join(dir, "by-reference");
    mkdirSync(out);
    assert.deepEqual(await unpackArchive(mine, out), new Map());
    assert.deepEqual(manifest(out), before);
    // A program started again in the workspace while it was archived left a socket there: the rest comes back.
    mkdirSync(ws, { recursive: true });
    put(join(ws, "new.txt"), "new while archived");
    await listen(join(ws, "again.sock"));
    await restoreWorkspace(room);
    assert.equal(existsSync(mine), false);
    assert.deepEqual(manifest(ws).filter((l) => !l.startsWith("new.txt ")), before, "no socket restored");
    assert.equal(readFileSync(join(ws, "new.txt"), "utf8"), "new while archived");
  } finally {
    for (const server of servers) await new Promise((done) => server.close(done));
  }
});

test("an archive another tar wrote (pax names and sizes, ustar's prefix) is restored and read as the reference reads it", { skip: unixOnly }, async () => {
  const dir = fresh();
  const room = join(dir, "room");
  mkdirSync(join(room, "workspace"), { recursive: true });
  // ("<length> <key>=<value>\n", its length counting its own digits)
  const record = (key: string, value: string) => {
    const body = Buffer.byteLength(` ${key}=${value}\n`);
    let n = body;
    while (String(n).length + body !== n) n = String(n).length + body;
    return `${n} ${key}=${value}\n`;
  };
  const meta = (size: number) => ({ mode: 0o100640, uid: 0, gid: 0, mtime: 1_600_000_000, size });
  const body = (b: Buffer) => [b, Buffer.alloc(padding(b.length).length)];
  const pax = Buffer.from(record("path", `uploads/${"由 pax 命名的".repeat(12)}.txt`) + record("size", "3"));
  const ustar = gnuHeader(Buffer.from("b.txt"), "0", meta(3));
  ustar.write("ustar\u000000", 257, "latin1");
  ustar.write("uploads/nested", 345, "latin1");
  ustar.fill(0x20, 148, 156);
  numberInto(ustar, 148, 8, checksum(ustar));
  await tarOfHeaders(workspaceArchive(room), [
    gnuHeader(Buffer.from("./"), "5", { ...meta(0), mode: 0o40750 }),
    gnuHeader(Buffer.from("pax"), "x", meta(pax.length)),
    ...body(pax),
    gnuHeader(Buffer.from("cut-short-by-pax"), "0", meta(99)),
    ...body(Buffer.from("ccc")),
    ustar,
    ...body(Buffer.from("bbb")),
    gnuHeader(Buffer.from("src/main.rs"), "0", meta(7)),
    ...body(Buffer.from("fn main")),
  ]);
  const archive = workspaceArchive(room);
  const paxName = `uploads/${"由 pax 命名的".repeat(12)}.txt`;
  assert.deepEqual(await workspaceFile(room, paxName), await fileOf(archive, paxName.split("/")));
  assert.deepEqual(await workspaceFile(room, "uploads/nested/b.txt"), Buffer.from("bbb"));
  const out = join(dir, "by-reference");
  mkdirSync(out);
  await unpackArchive(archive, out);
  const copy = join(dir, "copy.tar.zst");
  writeFileSync(copy, readFileSync(archive));
  await restoreWorkspace(room);
  assert.deepEqual(manifest(join(room, "workspace")), manifest(out));
  assert.equal(readFileSync(join(room, "workspace", paxName), "utf8"), "ccc");
  // Only the uploads, out of the same archive.
  writeFileSync(archive, readFileSync(copy));
  await emptyWorkspace(room);
  const uploads = join(dir, "uploads-by-reference");
  mkdirSync(uploads);
  await unpackArchive(copy, uploads, "uploads");
  assert.deepEqual(manifest(join(room, "workspace")), manifest(uploads));
});

test("an archive cut short, with bytes after it or not zstd at all is refused by each reader, the workspace and the archive kept", { skip: unixOnly }, async () => {
  const dir = fresh();
  const room = join(dir, "room");
  put(join(room, "workspace/uploads/a.txt"), "attachment");
  put(join(room, "workspace/source.rs"), "work");
  await packWorkspace(room);
  const whole = readFileSync(workspaceArchive(room));
  for (const [what, bytes] of [
    ["its checksum's last byte", whole.subarray(0, whole.length - 1)],
    ["half of it", whole.subarray(0, whole.length >> 1)],
    ["a frame header", whole.subarray(0, 6)],
    ["bytes after it", Buffer.concat([whole, Buffer.from("xx")])],
    ["not zstd", Buffer.from("broken archive")],
  ] as const) {
    writeFileSync(workspaceArchive(room), bytes);
    put(join(room, "workspace/uploads/new.txt"), "new");
    await assert.rejects(workspaceFile(room, "uploads/a.txt"), what);
    await assert.rejects(fileOf(workspaceArchive(room), ["uploads", "a.txt"]), `${what} (the reference)`);
    await assert.rejects(restoreWorkspace(room), /restoring the archived workspace/, what);
    await assert.rejects(emptyWorkspace(room), what);
    assert.deepEqual(readFileSync(workspaceArchive(room)), bytes, what);
    assert.equal(readFileSync(join(room, "workspace/uploads/new.txt"), "utf8"), "new", what);
    assert.deepEqual(readdirSync(room).filter((n) => n.includes("reading")), [], what);
  }
  writeFileSync(workspaceArchive(room), whole);
  await restoreWorkspace(room);
  assert.equal(readFileSync(join(room, "workspace/source.rs"), "utf8"), "work");
});

test("an archive that leads out of its workspace (`..`, a link made first, a hard link up) writes nothing outside it, as the reference", { skip: unixOnly }, async () => {
  const dir = fresh();
  const meta = (size: number) => ({ mode: 0o100644, uid: 0, gid: 0, mtime: 1_600_000_000, size });
  const entry = (name: string, kind: string, bytes = Buffer.alloc(0), link?: string) => [
    gnuHeader(Buffer.from(name), kind, meta(bytes.length), link === undefined ? undefined : Buffer.from(link)),
    bytes,
    padding(bytes.length),
  ];
  const cases: [string, Buffer[], RegExp | null][] = [
    ["`..` passed over", [...entry("../escaped", "0", Buffer.from("no")), ...entry("ok", "0", Buffer.from("yes"))], null],
    ["through a link out", [...entry("out", "2", Buffer.alloc(0), dir), ...entry("out/escaped", "0", Buffer.from("no"))], /trying to unpack outside of destination path/],
    ["a hard link up", entry("h", "1", Buffer.alloc(0), "../escaped"), /hard link outside of destination path/],
    ["a device", entry("tty", "3"), /cannot unpack a device file: tty/],
  ];
  for (const [what, blocks, refused] of cases) {
    const room = join(dir, what.replace(/\W/g, "-"));
    put(join(room, "workspace/kept.txt"), "kept");
    await tarOfHeaders(workspaceArchive(room), blocks);
    const reference = join(room, "by-reference");
    mkdirSync(reference);
    if (refused === null) {
      await unpackArchive(workspaceArchive(room), reference);
      await restoreWorkspace(room);
      assert.deepEqual(manifest(join(room, "workspace")).filter((l) => !l.startsWith("kept.txt")), manifest(reference), what);
    } else {
      await assert.rejects(unpackArchive(workspaceArchive(room), reference), refused, `${what} (the reference)`);
      await assert.rejects(restoreWorkspace(room), refused, what);
      assert.ok(existsSync(workspaceArchive(room)), what);
      assert.equal(readFileSync(join(room, "workspace/kept.txt"), "utf8"), "kept", what);
    }
    assert.equal(existsSync(join(dir, "escaped")), false, what);
  }
});
