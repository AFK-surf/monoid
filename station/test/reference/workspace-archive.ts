// What sessions/archive.ts packed and unpacked a workspace with before the shell did (client/shell `tar.pack`,
// `tar.unpack`, `tar.file`, asked through station/mb src/packed, `--builder packed`): a GNU tar as the tar crate writes
// it (the Rust station's archive.rs, test/archive-rs), zstd level 3 with its checksum, streamed through Node's zlib. The
// station keeps none of it: test/mb-packed.test.ts holds the shell to it both ways (what either packs, the other
// unpacks and reads a file of), and test/cold-compat.test.ts holds both to the Rust station's.
import { execFile } from "node:child_process";
import { type Dirent } from "node:fs";
import { chmod, link, lstat, mkdir, open, readdir, readlink, realpath, rm, unlink, utimes } from "node:fs/promises";
import { dirname, join, sep } from "node:path";
import { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";
import { promisify } from "node:util";
import { constants, createZstdCompress, createZstdDecompress } from "node:zlib";
import { link as symlinkOrStandIn } from "../../src/ops/links.ts";

const lstatOrNull = async (path: string) => {
  try {
    return await lstat(path);
  } catch {
    return null;
  }
};

/// Links the machine refused while a tree was made (Windows without the privilege): by their path, their target.
export type Refused = Map<string, string>;

// ── zstd ───────────────────────────────────────────────────────────────────────────────────────────────────────────

/// zstd level 3 with a checksum, as the Rust's encoder.
const compressor = () =>
  createZstdCompress({ params: { [constants.ZSTD_c_compressionLevel]: 3, [constants.ZSTD_c_checksumFlag]: 1 } });

/// A workspace's archive decompressed, as it comes: its frames whole (a cut stream fails, as the Rust's decoder's
/// "incomplete frame"; Node's decompressor ends quietly at a cut), their checksums verified. One frame, as both stations
/// write it (Node's zstd before 24.22 reads only the first of several): a transcript, in segments, is the MoonBit
/// program's to read (`packedProgram`).
function unzstd(path: string): Readable {
  return Readable.from(
    (async function* () {
      await wholeFrames(path);
      const raw = Readable.from(chunksOf(path));
      const out = createZstdDecompress();
      raw.on("error", (e) => out.destroy(e));
      raw.pipe(out);
      try {
        for await (const chunk of out) yield chunk as Buffer;
      } finally {
        raw.destroy();
        out.destroy();
      }
    })(),
    { objectMode: false },
  );
}

/// Walks a zstd file's frames by their headers (RFC 8878: frame header, block headers, checksum; skippable frames
/// skipped), failing unless each one is there whole.
async function wholeFrames(path: string): Promise<void> {
  const file = await open(path, "r");
  try {
    const size = (await file.stat()).size;
    const bytes = async (at: number, n: number) => {
      const buf = Buffer.alloc(n);
      const { bytesRead } = await file.read(buf, 0, n, at);
      if (bytesRead < n) throw new Error(`${path}: incomplete zstd frame`);
      return buf;
    };
    if (size === 0) throw new Error(`${path}: no zstd frame`);
    for (let at = 0; at < size; ) {
      const magic = (await bytes(at, 4)).readUInt32LE(0);
      if ((magic & 0xfffffff0) >>> 0 === 0x184d2a50) {
        at += 8 + (await bytes(at + 4, 4)).readUInt32LE(0);
        if (at > size) throw new Error(`${path}: incomplete zstd frame`);
        continue;
      }
      if (magic !== 0xfd2fb528) throw new Error(`${path}: not a zstd frame`);
      const descriptor = (await bytes(at + 4, 1))[0]!;
      const sizeFlag = descriptor >> 6;
      const single = (descriptor >> 5) & 1;
      const checksummed = (descriptor >> 2) & 1;
      const dictionary = [0, 1, 2, 4][descriptor & 3]!;
      const contentSize = sizeFlag === 0 ? single : [0, 2, 4, 8][sizeFlag]!;
      at += 5 + (single ? 0 : 1) + dictionary + contentSize;
      for (;;) {
        const head = await bytes(at, 3);
        const block = head[0]! | (head[1]! << 8) | (head[2]! << 16);
        const type = (block >> 1) & 3;
        if (type === 3) throw new Error(`${path}: reserved zstd block type`);
        at += 3 + (type === 1 ? 1 : block >>> 3);
        if (block & 1) break;
      }
      if (checksummed) at += 4;
      if (at > size) throw new Error(`${path}: incomplete zstd frame`);
    }
  } finally {
    await file.close();
  }
}

const CHUNK = 256 * 1024;

/// A file read in chunks, up to `limit` bytes (all of it by default).
async function* chunksOf(path: string, limit = Infinity): AsyncGenerator<Buffer> {
  const file = await open(path, "r");
  try {
    let left = limit;
    while (left > 0) {
      const buf = Buffer.allocUnsafe(Math.min(CHUNK, left));
      const { bytesRead } = await file.read(buf, 0, buf.length, null);
      if (bytesRead === 0) return;
      left -= bytesRead;
      yield buf.subarray(0, bytesRead);
    }
  } finally {
    await file.close();
  }
}

/// encoder + finish + sync_all: `source` compressed into `path` (made 0600), on disk before this returns.
async function compressInto(path: string, source: AsyncIterable<Buffer>): Promise<void> {
  const file = await open(path, "w", 0o600);
  try {
    await file.chmod(0o600);
    await pipeline(Readable.from(source), compressor(), async (compressed: AsyncIterable<Buffer>) => {
      for await (const chunk of compressed) await writeAll(file, chunk);
    });
    await file.sync();
  } finally {
    await file.close();
  }
}

async function writeAll(file: import("node:fs/promises").FileHandle, chunk: Buffer) {
  for (let at = 0; at < chunk.length; ) at += (await file.write(chunk, at, chunk.length - at)).bytesWritten;
}

/// A directory's entries made durable (File::open(dir).sync_all()), where a directory syncs (on Windows Node's is

// ── what packing compares ─────────────────────────────────────────────────────────────────────────────────────────────────────

/// Every path under `dir` with its size and modification time, symlinks not followed, Unix domain sockets left out
/// as the tar leaves them.
async function snapshot(dir: string, files: Map<string, string>): Promise<void> {
  for (const name of await readdir(dir)) {
    const path = join(dir, name);
    const meta = await lstat(path, { bigint: true });
    if (meta.isSocket()) continue;
    files.set(path, `${meta.size}:${meta.mtimeNs}`);
    if (meta.isDirectory()) await snapshot(path, files);
  }
}

const sameMap = (a: Map<string, string>, b: Map<string, string>) => a.size === b.size && [...a].every(([k, v]) => b.get(k) === v);

// ── tar, as the tar crate writes and reads it ──────────────────────────────────────────────────────────────────────

const BLOCK = 512;

/// A number into a header field: octal, zero-padded, NUL-ended; past what that holds, GNU's base-256.
function numberInto(header: Buffer, at: number, len: number, value: number | bigint) {
  const n = BigInt(value);
  const octal = n.toString(8);
  if (n >= 0n && octal.length <= len - 1) {
    header.write(octal.padStart(len - 1, "0"), at, "latin1");
    header[at + len - 1] = 0;
    return;
  }
  let rest = n < 0n ? 0n : n;
  for (let i = len - 1; i >= 1; i--) {
    header[at + i] = Number(rest & 0xffn);
    rest >>= 8n;
  }
  header[at] = 0x80;
}

/// A field's number: octal (spaces and NULs around it), or base-256 when its first byte's high bit is set.
function numberFrom(field: Buffer): number {
  if (field[0]! & 0x80) {
    let n = BigInt(field[0]! & 0x7f);
    for (const b of field.subarray(1)) n = n * 256n + BigInt(b);
    return Number(n);
  }
  const nul = field.indexOf(0);
  const text = (nul < 0 ? field : field.subarray(0, nul)).toString("latin1").trim();
  if (text === "") return 0;
  if (!/^[0-7]+$/.test(text)) throw new Error(`numeric field was not a number: ${text}`);
  return parseInt(text, 8);
}

const checksum = (header: Buffer) => {
  let sum = 8 * 32;
  for (let i = 0; i < BLOCK; i++) if (i < 148 || i >= 156) sum += header[i]!;
  return sum;
};

type Meta = { mode: number; uid: number; gid: number; mtime: number; size: number };

/// Header::new_gnu with its metadata (HeaderMode::Complete) and checksum.
function gnuHeader(name: Buffer, kind: string, meta: Meta, linkName?: Buffer, device?: [bigint, bigint]): Buffer {
  const h = Buffer.alloc(BLOCK);
  name.copy(h, 0, 0, Math.min(100, name.length));
  numberInto(h, 100, 8, meta.mode);
  numberInto(h, 108, 8, meta.uid);
  numberInto(h, 116, 8, meta.gid);
  numberInto(h, 124, 12, meta.size);
  numberInto(h, 136, 12, meta.mtime);
  h[156] = kind.charCodeAt(0);
  if (linkName) linkName.copy(h, 157, 0, Math.min(100, linkName.length));
  h.write("ustar ", 257, "latin1");
  h.write(" \0", 263, "latin1");
  if (device) {
    numberInto(h, 329, 8, device[0]);
    numberInto(h, 337, 8, device[1]);
  }
  h.fill(0x20, 148, 156);
  numberInto(h, 148, 8, checksum(h));
  return h;
}

const padding = (size: number) => Buffer.alloc((BLOCK - (size % BLOCK)) % BLOCK);

/// prepare_header: a GNU long name ('L') or long link name ('K') entry, for what does not fit 100 bytes.
function* longEntry(kind: "L" | "K", value: Buffer): Generator<Buffer> {
  const data = Buffer.concat([value, Buffer.alloc(1)]);
  yield gnuHeader(Buffer.from("././@LongLink"), kind, { mode: 0o644, uid: 0, gid: 0, mtime: 0, size: data.length });
  yield data;
  yield padding(data.length);
}

/// The first 100 bytes of a name, cut back to whole UTF-8 characters (set_truncated_path_for_gnu_header).
function truncated(name: Buffer): Buffer {
  let end = Math.min(100, name.length);
  while (end > 0 && end < name.length && (name[end]! & 0xc0) === 0x80) end--;
  return name.subarray(0, end);
}

/// Builder::append_dir_all(".", dir) with follow_symlinks(false), then finish: `./` for the directory itself, then
/// everything under it as `a/b` (directories before what is in them), symlinks as links, special files as headers.
async function* tarOf(dir: string): AsyncGenerator<Buffer> {
  const stack: [string, string][] = [[dir, ""]];
  while (stack.length > 0) {
    const [path, rel] = stack.pop()!;
    const meta = await lstat(path, { bigint: true });
    const name = Buffer.from(rel === "" ? "./" : rel, "utf8");
    const common = (size: number): Meta => ({
      mode: Number(meta.mode),
      uid: Number(meta.uid),
      gid: Number(meta.gid),
      mtime: Math.max(0, Number(meta.mtimeMs / 1000n)),
      size,
    });
    const head = function* (kind: string, size: number, linkName?: Buffer, device?: [bigint, bigint]) {
      if (name.length > 100) yield* longEntry("L", name);
      if (linkName && linkName.length > 100) yield* longEntry("K", linkName);
      yield gnuHeader(name.length > 100 ? truncated(name) : name, kind, common(size), linkName && linkName.length > 100 ? truncated(linkName) : linkName, device);
    };
    if (meta.isDirectory()) {
      // (by their names' bytes, whatever order the file system lists them in: as the shell's `tar.pack`)
      const children: Dirent[] = (await readdir(path, { withFileTypes: true })).sort((a, b) => Buffer.compare(Buffer.from(a.name), Buffer.from(b.name)));
      for (const child of children) stack.push([join(path, child.name), rel === "" ? child.name : `${rel}/${child.name}`]);
      yield* head("5", 0);
    } else if (meta.isSymbolicLink()) {
      yield* head("2", 0, Buffer.from(await readlink(path), "utf8"));
    } else if (meta.isFile()) {
      const size = Number(meta.size);
      yield* head("0", size);
      let sent = 0;
      for await (const chunk of chunksOf(path, size)) {
        sent += chunk.length;
        yield chunk;
      }
      if (sent !== size) throw new Error(`${path} changed while archiving`);
      yield padding(size);
    } else if (meta.isSocket()) {
      // A running program's endpoint, gone with it: tar has no entry for it.
      continue;
    } else {
      const kind = meta.isFIFO() ? "6" : meta.isCharacterDevice() ? "3" : meta.isBlockDevice() ? "4" : null;
      if (kind === null) throw new Error(`${path} has unknown file type`);
      const dev = meta.rdev;
      const major = ((dev >> 32n) & 0xfffff000n) | ((dev >> 8n) & 0x00000fffn);
      const minor = ((dev >> 12n) & 0xffffff00n) | (dev & 0x000000ffn);
      yield* head(kind, 0, undefined, [major, minor]);
    }
  }
  yield Buffer.alloc(2 * BLOCK);
}

/// Bytes pulled from a stream as they are needed.
class ByteReader {
  private chunks: Buffer[] = [];
  private have = 0;
  private ended = false;
  private readonly source: AsyncIterator<Buffer>;
  constructor(source: AsyncIterator<Buffer>) {
    this.source = source;
  }

  private async more(): Promise<boolean> {
    if (this.ended) return false;
    const next = await this.source.next();
    if (next.done) {
      this.ended = true;
      return false;
    }
    if (next.value.length > 0) {
      this.chunks.push(next.value);
      this.have += next.value.length;
    }
    return true;
  }

  /// Exactly `n` bytes; null at the very end, an error when it ends partway.
  async exact(n: number): Promise<Buffer | null> {
    while (this.have < n) {
      if (!(await this.more())) {
        if (this.have === 0) return null;
        throw new Error("unexpected end of archive");
      }
    }
    const out = Buffer.allocUnsafe(n);
    for (let at = 0; at < n; ) {
      const first = this.chunks[0]!;
      const take = Math.min(first.length, n - at);
      first.copy(out, at, 0, take);
      at += take;
      this.consume(take);
    }
    return out;
  }

  /// The next `n` bytes as they come; an error when it ends first.
  async *take(n: number): AsyncGenerator<Buffer> {
    while (n > 0) {
      if (this.have === 0 && !(await this.more())) throw new Error("unexpected end of archive");
      if (this.have === 0) continue;
      const first = this.chunks[0]!;
      const take = Math.min(first.length, n);
      const part = first.subarray(0, take);
      this.consume(take);
      n -= take;
      yield part;
    }
  }

  async skip(n: number) {
    for await (const _ of this.take(n));
  }

  /// Everything left read (the end of the zstd stream and its checksum).
  async drain() {
    this.chunks = [];
    this.have = 0;
    while (await this.more()) {
      this.chunks = [];
      this.have = 0;
    }
  }

  private consume(n: number) {
    const first = this.chunks[0]!;
    if (n === first.length) this.chunks.shift();
    else this.chunks[0] = first.subarray(n);
    this.have -= n;
  }
}

type EntryKind = "file" | "dir" | "symlink" | "hardlink" | "char" | "block" | "fifo" | "other";

type Entry = {
  /// The path's components ("." left out; a leading "/" when it had one).
  parts: string[];
  kind: EntryKind;
  mode: number;
  mtime: number;
  size: number;
  linkName: string | null;
  /// Its bytes, as they come (once).
  body(): AsyncGenerator<Buffer>;
  skip(): Promise<void>;
};

const nulEnded = (b: Buffer) => {
  const nul = b.indexOf(0);
  return nul < 0 ? b : b.subarray(0, nul);
};

const partsOf = (raw: Buffer): string[] => {
  const text = raw.toString("utf8");
  const parts = text.split("/").filter((p) => p !== "" && p !== ".");
  return text.startsWith("/") ? ["/", ...parts] : parts;
};

/// pax records ("<length> <key>=<value>\n") by key.
function paxRecords(data: Buffer): Map<string, Buffer> {
  const out = new Map<string, Buffer>();
  for (let rest = data; rest.length > 0; ) {
    const space = rest.indexOf(0x20);
    const len = space < 0 ? NaN : parseInt(rest.subarray(0, space).toString("latin1"), 10);
    if (!(len > space + 1) || len > rest.length) break;
    const record = rest.subarray(space + 1, len - 1);
    rest = rest.subarray(len);
    const eq = record.indexOf(0x3d);
    if (eq >= 0) out.set(record.subarray(0, eq).toString("latin1"), record.subarray(eq + 1));
  }
  return out;
}

/// Archive::entries: each entry named by the GNU long name or pax path before it, else its name (with the ustar prefix
/// for a ustar header); headers' checksums checked; the archive ends at a zero block. An entry's body not read is
/// skipped when the next is asked for.
async function* tarEntries(bytes: ByteReader): AsyncGenerator<Entry> {
  let longName: Buffer | null = null;
  let longLink: Buffer | null = null;
  let pax: Map<string, Buffer> | null = null;
  for (;;) {
    const h = await bytes.exact(BLOCK);
    if (h === null || h.every((x) => x === 0)) return;
    const sum = numberFrom(h.subarray(148, 156));
    if (sum !== checksum(h)) throw new Error("archive header checksum mismatch");
    const type = String.fromCharCode(h[156]!);
    let size = numberFrom(h.subarray(124, 136));
    const paxSize = pax?.get("size");
    if (paxSize !== undefined && type !== "x" && type !== "g" && type !== "L" && type !== "K") size = Number(paxSize.toString("latin1"));
    const pad = (BLOCK - (size % BLOCK)) % BLOCK;
    const read = async () => {
      const out: Buffer[] = [];
      for await (const chunk of bytes.take(size)) out.push(chunk);
      await bytes.skip(pad);
      return Buffer.concat(out);
    };
    if (type === "L") {
      longName = nulEnded(await read());
      continue;
    }
    if (type === "K") {
      longLink = nulEnded(await read());
      continue;
    }
    if (type === "x") {
      pax = paxRecords(await read());
      continue;
    }
    if (type === "g") {
      await read();
      continue;
    }
    const ustar = h.subarray(257, 263).toString("latin1") === "ustar\0";
    const prefix = ustar ? nulEnded(h.subarray(345, 500)) : Buffer.alloc(0);
    const name = nulEnded(h.subarray(0, 100));
    const raw = longName ?? pax?.get("path") ?? (prefix.length > 0 ? Buffer.concat([prefix, Buffer.from("/"), name]) : name);
    const link = longLink ?? pax?.get("linkpath") ?? nulEnded(h.subarray(157, 257));
    longName = longLink = pax = null;
    const kind: EntryKind =
      type === "0" || type === "\0" || type === "7"
        ? "file"
        : type === "5"
          ? "dir"
          : type === "2"
            ? "symlink"
            : type === "1"
              ? "hardlink"
              : type === "3"
                ? "char"
                : type === "4"
                  ? "block"
                  : type === "6"
                    ? "fifo"
                    : "other";
    let left = size;
    let padLeft = pad;
    const entry: Entry = {
      parts: partsOf(raw),
      kind,
      mode: numberFrom(h.subarray(100, 108)),
      mtime: numberFrom(h.subarray(136, 148)),
      size,
      linkName: kind === "symlink" || kind === "hardlink" ? link.toString("utf8") : null,
      async *body() {
        for await (const chunk of bytes.take(left)) {
          left -= chunk.length;
          yield chunk;
        }
      },
      async skip() {
        await bytes.skip(left);
        left = 0;
        await bytes.skip(padLeft);
        padLeft = 0;
      },
    };
    yield entry;
    await entry.skip();
  }
}

const execFileP = promisify(execFile);

/// Archive::unpack with preserve_permissions: entries with `..` skipped, a leading `/` dropped, nothing written through
/// a symlink out of `dest`; directories made last, deepest first, with their modes; files with their modes and
/// modification times.
async function unpack(entries: AsyncGenerator<Entry>, dest: string, refused: Refused): Promise<void> {
  const root = await realpath(dest);
  const dirs: { path: string; key: string; mode: number }[] = [];
  const inside = async (dir: string) => {
    const real = await realpath(dir);
    if (real !== root && !real.startsWith(root.endsWith(sep) ? root : `${root}${sep}`)) throw new Error(`trying to unpack outside of destination path: ${root}`);
  };
  for await (const entry of entries) {
    const parts = entry.parts.filter((p) => p !== "/");
    if (parts.length === 0 || parts.includes("..")) continue;
    const path = join(dest, ...parts);
    if (entry.kind === "dir") {
      dirs.push({ path, key: parts.join("/"), mode: entry.mode });
      continue;
    }
    if (entry.kind === "other") continue;
    await mkdir(dirname(path), { recursive: true });
    await inside(dirname(path));
    const replace = async <T>(make: () => Promise<T>): Promise<T> => {
      try {
        return await make();
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
        await unlink(path);
        return make();
      }
    };
    if (entry.kind === "file") {
      const file = await replace(() => open(path, "wx", 0o600));
      try {
        for await (const chunk of entry.body()) await writeAll(file, chunk);
      } finally {
        await file.close();
      }
      const mtime = entry.mtime === 0 ? 1 : entry.mtime;
      await utimes(path, mtime, mtime);
      await chmod(path, entry.mode & 0o7777);
    } else if (entry.kind === "symlink") {
      await replace(async () => {
        if ((await symlinkOrStandIn(entry.linkName!, path, {})) === "refused") refused.set(path, entry.linkName!);
      });
    } else if (entry.kind === "hardlink") {
      const target = entry.linkName!.split("/").filter((p) => p !== "" && p !== ".");
      if (target.includes("..")) throw new Error(`hard link outside of destination path: ${entry.linkName}`);
      const from = join(dest, ...target);
      await inside(dirname(from));
      await replace(() => link(from, path));
    } else if (entry.kind === "fifo") {
      await replace(() => execFileP("mkfifo", ["-m", (entry.mode & 0o7777).toString(8), path]));
    } else {
      throw new Error(`cannot unpack a device file: ${parts.join("/")}`);
    }
  }
  dirs.sort((a, b) => Buffer.compare(Buffer.from(b.key), Buffer.from(a.key)));
  for (const dir of dirs) {
    const there = await lstatOrNull(dir.path);
    if (there && !there.isDirectory()) throw new Error(`${dir.key} is not a directory in the archive's tree`);
    if (!there) {
      await mkdir(dirname(dir.path), { recursive: true });
      await inside(dirname(dir.path));
      await mkdir(dir.path);
    }
    await chmod(dir.path, dir.mode & 0o7777);
  }
}

// ── what archive.ts did with them ──────────────────────────────────────────────────────────────────────────────────

/// `packWorkspaceIf`'s packing of before: the tree at `dir` into `out`, read back to the end of its zstd stream, the tree
/// found unchanged meanwhile.
export async function packTree(dir: string, out: string): Promise<void> {
  const before = new Map<string, string>();
  await snapshot(dir, before);
  await compressInto(out, tarOf(dir));
  const check = unzstd(out);
  try {
    const bytes = new ByteReader(check[Symbol.asyncIterator]());
    for await (const entry of tarEntries(bytes)) await entry.skip();
    await bytes.drain();
  } finally {
    check.destroy();
  }
  const after = new Map<string, string>();
  await snapshot(dir, after);
  if (!sameMap(before, after)) throw new Error("workspace changed while archiving; originals kept");
}

/// `restoreWorkspace`'s (and, with `prefix`, `emptyWorkspace`'s) unpacking of before: the archive made in `dest`; the
/// links refused.
export async function unpackArchive(archive: string, dest: string, prefix?: string): Promise<Refused> {
  const stream = unzstd(archive);
  const refused: Refused = new Map();
  try {
    const bytes = new ByteReader(stream[Symbol.asyncIterator]());
    const only = async function* () {
      for await (const entry of tarEntries(bytes)) {
        if (prefix === undefined || (entry.parts[0] === prefix && (entry.kind === "file" || entry.kind === "dir"))) yield entry;
      }
    };
    await unpack(only(), dest, refused);
    await bytes.drain();
  } finally {
    stream.destroy();
  }
  return refused;
}

/// `workspaceFile`'s reading of before: the file whose path's components are `wanted`, or null.
export async function fileOf(archive: string, wanted: string[]): Promise<Buffer | null> {
  const stream = unzstd(archive);
  try {
    const bytes = new ByteReader(stream[Symbol.asyncIterator]());
    for await (const entry of tarEntries(bytes)) {
      const parts = entry.parts.filter((p) => p !== "/");
      if (entry.parts[0] !== "/" && parts.length === wanted.length && parts.every((p, i) => p === wanted[i]) && entry.kind === "file") {
        const out: Buffer[] = [];
        for await (const chunk of entry.body()) out.push(chunk);
        return Buffer.concat(out);
      }
    }
    return null;
  } finally {
    stream.destroy();
  }
}

/// A tar of `entries` as another program writes one (headers of the tests' own: pax, ustar's prefix), zstd'ed.
export async function tarOfHeaders(out: string, blocks: Buffer[]): Promise<void> {
  await compressInto(out, (async function* () {
    for (const b of blocks) yield b;
    yield Buffer.alloc(2 * BLOCK);
  })());
}

export { BLOCK, checksum, gnuHeader, numberInto, padding, wholeFrames };
