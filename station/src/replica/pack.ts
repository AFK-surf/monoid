// A pack (replica/sending.ts sends files by them, handover.ts and retire.ts take them): its bytes made and taken, of
// node's own modules and the bus's `Refused` alone, so that what makes or takes one (a worker of a small heap,
// sending-pack.test.ts) loads no more of the station than that.
import { createHash, randomBytes } from "node:crypto";
import { constants as fsConstants } from "node:fs";
import { type FileHandle, mkdir, open, rename, rm, stat } from "node:fs/promises";
import { join } from "node:path";
import { constants as zlibConstants, createZstdCompress, createZstdDecompress } from "node:zlib";
import { type Bytes, Refused } from "../mesh/bus.ts";

export const WENT = "a file went as it was sent: gathered again";
export const CHANGED = "a file changed as it was sent: gathered again";

/// How a pack is said to be (`lacking`'s `pack` where a station takes them, a `put`'s where it is one).
export const PACK_ENCODING = "zstd";
/// The most files and bytes (as gathered) of one pack: each pack one request, a few seconds of the other's disk at
/// most, so that what one meeting no answer sends again is bounded. A file larger goes in a pack alone.
export const PACK_MAX_FILES = 500;
export const PACK_MAX_BYTES = 32 * 1024 * 1024;

/// A file of a pack: its hash, where it is here and its bytes (as gathered; as read, once it went).
export type PackEntry = { hash: string; path: string; size: number };

// A pack, in zstd: "SFP1", then each file as an entry (ENTRY and its hash's 32 bytes, its bytes in DATA frames of a
// u32be length and that many bytes, then COMMIT where they are what its name says, ABORT where not), then END. A file
// is read as it goes, so one that changes as it is read (its chat working while the first pass sends it) is known only
// once it was: an entry with no length up front can be called off after its bytes went, and the files after it go on in
// the same stream (a tar's header says its length first, and a file found shorter would break the stream).
const MAGIC = Buffer.from("SFP1");
const END = 0x00;
const ENTRY = 0x01;
const DATA = 0x02;
const COMMIT = 0x03;
const ABORT = 0x04;
/// What a DATA frame holds at most (a sender's PIECE, a receiver's bound).
const PIECE = 256 * 1024;
const FRAME_MOST = 4 * 1024 * 1024;
/// How much of the pack is gathered before it goes to the compressor at once.
const STAGE = 256 * 1024;

/// A zstd stream of node:zlib, written a piece at a time and read as it gives: a piece's output taken whole before the
/// next is written, and its output no more than the stream's own buffer ahead of what is taken (zlib waits for a
/// read past its high-water mark), so a file of zeros inflating a thousandfold is not one buffer.
class Pump {
  readonly #z: ReturnType<typeof createZstdCompress> | ReturnType<typeof createZstdDecompress>;
  #failure: Error | null = null;
  #ended = false;
  #wake: (() => void) | null = null;
  constructor(z: ReturnType<typeof createZstdCompress> | ReturnType<typeof createZstdDecompress>) {
    this.#z = z;
    z.on("readable", () => this.#poke());
    z.on("end", () => ((this.#ended = true), this.#poke()));
    z.on("error", (e: Error) => ((this.#failure ??= e), this.#poke()));
  }

  #poke(): void {
    const wake = this.#wake;
    this.#wake = null;
    wake?.();
  }

  async *#drain(done: () => boolean): AsyncGenerator<Buffer> {
    for (;;) {
      if (this.#failure !== null) throw this.#failure;
      const out = this.#z.read() as Buffer | null;
      if (out !== null) {
        yield out;
        continue;
      }
      if (done()) return;
      await new Promise<void>((wake) => (this.#wake = wake));
    }
  }

  /// `piece` written, what comes of it given.
  async *push(piece: Buffer): AsyncGenerator<Buffer> {
    let written = false;
    this.#z.write(piece, (e) => {
      if (e) this.#failure ??= e;
      written = true;
      this.#poke();
    });
    yield* this.#drain(() => written);
  }

  /// The stream ended, the rest of what comes of it given.
  async *finish(): AsyncGenerator<Buffer> {
    this.#z.end();
    yield* this.#drain(() => this.#ended);
  }

  destroy(): void {
    this.#z.destroy();
  }
}

/// The bytes of a pack of `entries`, read as they are sent (each file opened as its turn comes, one at a time, closed
/// after it or as the sending stops): at most a stage and the compressor's window in memory, whatever the files'
/// size. `took`: each whose bytes went whole and were what its name says, as it went. One gone or changed as it is read
/// is called off and the rest go on, not `strict`; `strict`, the bytes fail with it (the caller is told it as the
/// source's failure: mesh/peer.ts). `stopping`: no file more is begun, the pack ended.
export async function* packBytes(entries: PackEntry[], strict: boolean, took: PackEntry[], stopping: () => boolean = () => false): Bytes {
  const z = new Pump(createZstdCompress({
    chunkSize: PIECE,
    params: { [zlibConstants.ZSTD_c_compressionLevel]: 1, [zlibConstants.ZSTD_c_windowLog]: 20 },
  }));
  let staged: Buffer[] = [MAGIC];
  let stagedBytes = MAGIC.length;
  const stage = (b: Buffer) => {
    staged.push(b);
    stagedBytes += b.length;
  };
  const flush = () => {
    const all = Buffer.concat(staged, stagedBytes);
    staged = [];
    stagedBytes = 0;
    return z.push(all);
  };
  let file: FileHandle | null = null;
  try {
    for (const f of entries) {
      if (stopping()) break;
      // (gone since it was gathered, or between its `stat` and its open: left for the next gathering while the chats
      // work; once they are held the gathering is made again, so that the other station is sent all its lists name)
      const size = await stat(f.path).then((s) => s.size, () => null);
      if (size !== null) {
        file = await open(f.path, fsConstants.O_RDONLY | fsConstants.O_NOFOLLOW | fsConstants.O_NONBLOCK).catch((e) => {
          if ((e as NodeJS.ErrnoException)?.code !== "ENOENT") throw e;
          return null;
        });
      }
      if (size === null || file === null) {
        if (strict) throw new Error(WENT);
        continue;
      }
      stage(Buffer.of(ENTRY));
      stage(Buffer.from(f.hash, "hex"));
      const h = createHash("sha256");
      let at = 0;
      while (at < size) {
        const piece = Buffer.allocUnsafe(Math.min(PIECE, size - at));
        const { bytesRead } = await file.read(piece, 0, piece.length, at);
        if (bytesRead === 0) break;
        const data = piece.subarray(0, bytesRead);
        h.update(data);
        at += bytesRead;
        const head = Buffer.allocUnsafe(5);
        head[0] = DATA;
        head.writeUInt32BE(bytesRead, 1);
        stage(head);
        stage(data);
        if (stagedBytes >= STAGE) yield* flush();
      }
      const handle = file;
      file = null;
      await handle.close();
      // (shorter than it was as it was looked at, or not the bytes it was gathered with: changed as it was read)
      if (at < size || h.digest("hex") !== f.hash) {
        if (strict) throw new Error(CHANGED);
        stage(Buffer.of(ABORT));
        continue;
      }
      stage(Buffer.of(COMMIT));
      took.push({ hash: f.hash, path: f.path, size });
    }
    stage(Buffer.of(END));
    yield* flush();
    yield* z.finish();
  } finally {
    await file?.close().catch(() => {});
    z.destroy();
  }
}

/// A pack sent (`packBytes`), taken into `files` by each file's hash as `receiveFile` takes one: written beside, its
/// bytes' hash checked as they come, then put in place; one there already let go by. A piece of the stream is taken
/// whole (written, flushed where `flush`, renamed) before the next is read, so a disk that fails stops it at once.
/// `strict`: one whose bytes are not what its name says refuses the pack (else it is left: the sender called it off
/// as it changed). `name`: the one file it says it holds (a pack of one), each entry checked against it. `count`: the
/// most entries. `onFile`: told as each begins.
export async function receivePack(files: string, bytes: Bytes, opts: { strict: boolean; flush?: boolean; name?: string; count?: number; onFile?: () => void }): Promise<void> {
  await mkdir(files, { recursive: true });
  const z = new Pump(createZstdDecompress({ chunkSize: PIECE, params: { [zlibConstants.ZSTD_d_windowLogMax]: 22 } }));
  const unpack = new Unpacking(files, opts);
  try {
    for await (const piece of bytes) for await (const out of z.push(piece)) await unpack.take(out);
    for await (const out of z.finish()) await unpack.take(out);
    if (!unpack.ended) throw new Refused("bad pack: it ended before its end");
  } finally {
    z.destroy();
    await unpack.close();
  }
}

/// A pack's entries as its bytes come, a piece at a time.
class Unpacking {
  readonly #files: string;
  readonly #opts: { strict: boolean; flush?: boolean; name?: string; count?: number; onFile?: () => void };
  /// Where it is: the magic, a tag, an entry's hash, a frame's length, its bytes (`#left` of them).
  #at: "magic" | "tag" | "hash" | "length" | "data" = "magic";
  /// A head being read (magic, hash, length) and how much of it came.
  #head = Buffer.alloc(32);
  #had = 0;
  #left = 0;
  #entries = 0;
  ended = false;
  #entry: { hash: string; path: string; bad: boolean; tmp: string | null; f: FileHandle | null; h: ReturnType<typeof createHash> | null } | null = null;

  constructor(files: string, opts: { strict: boolean; flush?: boolean; name?: string; count?: number; onFile?: () => void }) {
    this.#files = files;
    this.#opts = opts;
  }

  /// Of `b` from `at`, the head of `n` bytes filled; whether it is whole, and where `b` is read to.
  #fill(b: Buffer, at: number, n: number): number {
    const take = Math.min(n - this.#had, b.length - at);
    b.copy(this.#head, this.#had, at, at + take);
    this.#had += take;
    return at + take;
  }

  async take(b: Buffer): Promise<void> {
    for (let at = 0; at < b.length; ) {
      switch (this.#at) {
        case "magic":
          at = this.#fill(b, at, 4);
          if (this.#had < 4) break;
          if (!this.#head.subarray(0, 4).equals(MAGIC)) throw new Refused("bad pack: not a pack");
          this.#had = 0;
          this.#at = "tag";
          break;
        case "tag": {
          const tag = b[at++];
          if (this.ended) throw new Refused("bad pack: more after its end");
          if (tag === END) {
            if (this.#entry !== null) throw new Refused("bad pack: an entry not ended");
            this.ended = true;
          } else if (tag === ENTRY) {
            if (this.#entry !== null) throw new Refused("bad pack: an entry not ended");
            this.#at = "hash";
          } else if (tag === DATA) {
            if (this.#entry === null) throw new Refused("bad pack: bytes of no entry");
            this.#at = "length";
          } else if (tag === COMMIT) await this.#commit();
          else if (tag === ABORT) await this.#abort();
          else throw new Refused("bad pack: an unknown frame");
          break;
        }
        case "hash":
          at = this.#fill(b, at, 32);
          if (this.#had < 32) break;
          this.#had = 0;
          this.#at = "tag";
          await this.#begin(this.#head.toString("hex"));
          break;
        case "length":
          at = this.#fill(b, at, 4);
          if (this.#had < 4) break;
          this.#had = 0;
          this.#left = this.#head.readUInt32BE(0);
          if (this.#left === 0 || this.#left > FRAME_MOST) throw new Refused("bad pack: a frame's length");
          this.#at = "data";
          break;
        case "data": {
          const take = Math.min(this.#left, b.length - at);
          await this.#write(b.subarray(at, at + take));
          at += take;
          this.#left -= take;
          if (this.#left === 0) this.#at = "tag";
          break;
        }
      }
    }
  }

  async #begin(hash: string): Promise<void> {
    if (this.#opts.count !== undefined && ++this.#entries > this.#opts.count) throw new Refused("bad pack: more files than it said");
    this.#opts.onFile?.();
    const path = join(this.#files, hash);
    const entry = { hash, path, bad: this.#opts.name !== undefined && hash !== this.#opts.name, tmp: null as string | null, f: null as FileHandle | null, h: null as ReturnType<typeof createHash> | null };
    this.#entry = entry;
    if (await there(path)) return;
    entry.tmp = `${path}.${randomBytes(4).toString("hex")}.tmp`;
    entry.f = await open(entry.tmp, "w");
    entry.h = createHash("sha256");
  }

  async #write(piece: Buffer): Promise<void> {
    const e = this.#entry!;
    if (e.f === null) return;
    e.h!.update(piece);
    for (let done = 0; done < piece.length; ) done += (await e.f.write(piece, done, piece.length - done)).bytesWritten;
  }

  async #commit(): Promise<void> {
    const e = this.#entry;
    if (e === null) throw new Refused("bad pack: an end of no entry");
    if (e.f !== null) {
      if (this.#opts.flush !== false) await e.f.sync();
      const f = e.f;
      e.f = null;
      await f.close();
    }
    if (e.bad || (e.h !== null && e.h.digest("hex") !== e.hash)) {
      if (e.tmp !== null) await rm(e.tmp, { force: true });
      this.#entry = null;
      if (this.#opts.strict || e.bad) throw new Refused("changed: its bytes are not what its name says");
      return;
    }
    if (e.tmp !== null) await rename(e.tmp, e.path);
    this.#entry = null;
  }

  async #abort(): Promise<void> {
    if (this.#entry === null) throw new Refused("bad pack: an end of no entry");
    await this.close();
  }

  /// The entry under way let go: its file closed, what it wrote taken out.
  async close(): Promise<void> {
    const e = this.#entry;
    this.#entry = null;
    if (e === null) return;
    await e.f?.close().catch(() => {});
    if (e.tmp !== null) await rm(e.tmp, { force: true });
  }
}

export const there = (path: string) => stat(path).then(() => true, () => false);

/// Of `hashes`, those not in `files` (a station taking another's files).
export async function lackingIn(files: string, hashes: string[]): Promise<string[]> {
  const held = await Promise.all(hashes.map((h) => there(join(files, h))));
  return hashes.filter((_, i) => !held[i]);
}
