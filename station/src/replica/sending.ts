// What a gathering (carry.ts) names, sent to another station a bounded batch at a time, and taken there by its
// hash: what a station retired (retire.ts) and a chat handed over (handover.ts) both send their files by. Each session's
// list is read as it streams, what the other lacks asked of in batches (`lacking`, at most `most` hashes), each file it
// lacks sent (`put`), then the list itself; nothing of it is one object on the main thread. Where the other says it
// takes them so (`lacking`'s `pack`), what it lacks of a batch goes a pack at a time, in zstd (`packBytes`): a request
// a file was 252k requests in a row, 182 s between a VM and its own host, for a chat of 252k files (the drill of
// 2026-11-16).
import { execFile } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import { constants as fsConstants, createReadStream } from "node:fs";
import { type FileHandle, mkdir, open, readFile, rename, rm, stat } from "node:fs/promises";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { promisify } from "node:util";
import { constants as zlibConstants, createZstdCompress, createZstdDecompress } from "node:zlib";
import { type Bytes, Refused, withBytes } from "../mesh/bus.ts";
import { platform } from "../platform/index.ts";
import { AskAgain } from "../move/module.ts";
import { fileBytes, oneBytes } from "../mesh/files.ts";
import type { CarryIndex, Gathered } from "./carry.ts";

type Json = any;

const run = promisify(execFile);

/// How a sending reaches the other station and says how far it went.
export type Sending = {
  /// Asks of the other station what of `hashes` it lacks (its answer's `lacking`); `files`: each with where it is put
  /// and how big (a station that keeps a copy of the room says which it has in place already).
  lacking(hashes: string[], files: { hash: string; path: string; size: number; mtimeMs?: number; room?: string }[]): Promise<Json>;
  /// Sends it one file by its hash (`path`: where it is here; "" for a list or the index).
  put(hash: string, bytes: Bytes, path: string, size: number): Promise<Json>;
  /// Sends it `entries` in one pack (`packBytes`), where its `lacking` said it takes them so (`pack`); none: each by
  /// `put`.
  putPack?(entries: PackEntry[], bytes: Bytes, strict: boolean): Promise<Json>;
  /// Told of each file of a pack that is there now, as it was read here (`size`: its bytes).
  took?(f: PackEntry): void;
  /// The most files and bytes one pack holds (PACK_MAX_FILES, PACK_MAX_BYTES; a test's smaller).
  packMost?: { files?: number; bytes?: number };
  /// The most hashes one `lacking` asks of.
  most: number;
  /// Whether to stop between files (a cancel, the process closing).
  stopping(): boolean;
  /// The bytes the index names, as it is read (`total`), and `done` of them as each goes (or was there).
  total(bytes: number): void;
  done(bytes: number): void;
  /// Told, before any file is sent, the bytes of what the other lacks (each file it has not in place, once): what the
  /// sending adds to its disk at the most, all of it held there before it is placed. Throws to send nothing.
  adds?(bytes: number): Promise<void> | void;
};

/// The bytes of what the other lacks of `index`'s sessions' files (each by its hash once), asked as the sending asks.
async function lackingBytes(index: CarryIndex, to: Sending): Promise<number> {
  const counted = new Set<string>();
  let bytes = 0;
  const ask = async (batch: { hash: string; path: string; size: number; mtimeMs?: number; room?: string }[]) => {
    if (batch.length === 0) return;
    const asked = [...new Set(batch.map((f) => f.hash))];
    const answer = await to.lacking(asked, batch);
    const lacking = new Set<string>(Array.isArray(answer?.lacking) ? answer.lacking : asked);
    for (const f of batch) {
      if (!lacking.has(f.hash) || counted.has(f.hash)) continue;
      counted.add(f.hash);
      bytes += f.size;
    }
  };
  for (const session of [...index.sessions, ...(index.agent ? [index.agent] : [])]) {
    let batch: { hash: string; path: string; size: number; mtimeMs?: number; room?: string }[] = [];
    const room = "workspace" in session && typeof session.workspace === "string" ? session.workspace : undefined;
    const lines = createInterface({ input: createReadStream(session.at), crlfDelay: Infinity });
    try {
      for await (const line of lines) {
        if (to.stopping()) return bytes;
        if (line === "") continue;
        const f = JSON.parse(line);
        if (typeof f?.hash !== "string") continue;
        batch.push({ hash: f.hash, path: f.path, size: f.size, mtimeMs: f.mtimeMs, ...(room !== undefined ? { room } : {}) });
        if (batch.length >= to.most) {
          await ask(batch);
          batch = [];
        }
      }
    } finally {
      lines.close();
    }
    await ask(batch);
  }
  return bytes;
}

/// What the gathering `g` names that the other station lacks, sent: each session's list as it streams, then the list
/// itself (`strict`); the bundles; the index last (with `jobs` in it), its hash said back (null: stopped, or not
/// `strict`). A file that changed since it was gathered is refused there: left for the next gathering while the chats
/// work, gathered again (the step tried again, thrown) once they are held (`strict`). The agent home's list is one more.
/// `indexed`: the index put (its hash said back) where not `strict` too, so what was sent can be placed already.
export async function sendGathered(g: Gathered, to: Sending, strict: boolean, jobs: unknown[] = [], indexed = false): Promise<string | null> {
  const index = JSON.parse(await readFile(g.index, "utf8")) as CarryIndex;
  if (to.adds !== undefined) await to.adds(await lackingBytes(index, to));
  to.total(index.bytes);
  for (const session of [...index.sessions, ...(index.agent ? [index.agent] : [])]) {
    let batch: { hash: string; path: string; size: number; mtimeMs?: number; room?: string }[] = [];
    // (the session's room, by which the other finds where a file of it lies there: restore.ts `carriedTo`)
    const room = "workspace" in session && typeof session.workspace === "string" ? session.workspace : undefined;
    const lines = createInterface({ input: createReadStream(session.at), crlfDelay: Infinity });
    try {
      for await (const line of lines) {
        if (to.stopping()) return null;
        if (line === "") continue;
        const f = JSON.parse(line);
        if (typeof f?.hash !== "string") continue;
        batch.push({ hash: f.hash, path: f.path, size: f.size, mtimeMs: f.mtimeMs, ...(room !== undefined ? { room } : {}) });
        if (batch.length >= to.most) {
          await sendBatch(to, batch, strict);
          batch = [];
        }
      }
    } finally {
      lines.close();
    }
    await sendBatch(to, batch, strict);
    // (its list too where the index goes, so what was sent can be placed by it)
    if (strict || indexed) await sendBatch(to, [{ hash: session.list, path: session.at, size: 0 }], strict);
  }
  await sendBatch(to, Object.entries(index.bundles).map(([hash, path]) => ({ hash, path, size: 0 })), strict);
  if (to.stopping() || (!strict && !indexed)) return null;
  index.jobs = jobs as CarryIndex["jobs"];
  const text = Buffer.from(JSON.stringify(index));
  const hash = createHash("sha256").update(text).digest("hex");
  await to.put(hash, oneBytes(text), "", text.length).catch((e) => {
    if (!(e instanceof AskAgain)) throw e;
    return to.put(hash, oneBytes(text), "", text.length);
  });
  return hash;
}

/// Of `batch`, what the other station lacks, sent.
async function sendBatch(to: Sending, batch: { hash: string; path: string; size: number; mtimeMs?: number; room?: string }[], strict: boolean): Promise<void> {
  if (batch.length === 0) return;
  const asked = [...new Set(batch.map((f) => f.hash))];
  const answer = await to.lacking(asked, batch);
  const lacking = new Set<string>(Array.isArray(answer?.lacking) ? answer.lacking : asked);
  // (a station that takes packs: what it lacks of the batch goes a pack at a time; one from before, a file a request)
  if (answer?.pack === PACK_ENCODING && to.putPack !== undefined) return await sendPacked(to, batch, lacking, strict);
  for (const f of batch) {
    if (to.stopping()) return;
    if (lacking.delete(f.hash)) {
      let size = 0;
      try {
        size = (await stat(f.path)).size;
      } catch {
        // (gone since it was gathered: left for the next gathering while the chats work; once they are held the
        // gathering is made again, so that the other station is sent all its lists name)
        if (strict) throw new Error(WENT);
        continue;
      }
      try {
        // (its request meeting the other's connection gone, the first time in a turn: sent again from its start)
        await to.put(f.hash, fileBytes(f.path, 0, size), f.path, size).catch((e) => {
          if (!(e instanceof AskAgain)) throw e;
          return to.put(f.hash, fileBytes(f.path, 0, size), f.path, size);
        });
      } catch (e) {
        // (gone between its `stat` and its open: as one gone since it was gathered, above)
        if ((e as NodeJS.ErrnoException)?.code === "ENOENT") {
          if (strict) throw new Error(WENT);
          continue;
        }
        if (!(e instanceof Refused && /changed/.test(e.message)) && !/got shorter/.test((e as Error).message)) throw e;
        if (strict) throw new Error(CHANGED);
        continue;
      }
    }
    to.done(f.size);
  }
}

const WENT = "a file went as it was sent: gathered again";
const CHANGED = "a file changed as it was sent: gathered again";

/// How a pack is said to be (`lacking`'s `pack` where a station takes them, a `put`'s where it is one).
export const PACK_ENCODING = "zstd";
/// The most files and bytes (as gathered) of one pack: each pack one request, a few seconds of the other's disk at
/// most, so that what one meeting no answer sends again is bounded. A file larger goes in a pack alone.
export const PACK_MAX_FILES = 500;
export const PACK_MAX_BYTES = 32 * 1024 * 1024;

/// A file of a pack: its hash, where it is here and its bytes (as gathered; as read, once it went).
export type PackEntry = { hash: string; path: string; size: number };

/// What `lacking` says of `batch`, sent a pack at a time: each file by its hash once, the batch's order kept.
async function sendPacked(to: Sending, batch: { hash: string; path: string; size: number }[], lacking: Set<string>, strict: boolean): Promise<void> {
  const sending: PackEntry[] = [];
  const of = new Map<string, { size: number }[]>();
  for (const f of batch) {
    if (lacking.delete(f.hash)) {
      // (a list's or a bundle's size is not in the gathering: its own, to bound its pack by)
      const size = f.size > 0 ? f.size : await stat(f.path).then((s) => s.size, () => 0);
      sending.push({ hash: f.hash, path: f.path, size });
      of.set(f.hash, []);
    }
    const waiting = of.get(f.hash);
    if (waiting !== undefined) waiting.push(f);
    else to.done(f.size);
  }
  const files = Math.max(1, to.packMost?.files ?? PACK_MAX_FILES);
  const most = Math.max(1, to.packMost?.bytes ?? PACK_MAX_BYTES);
  for (let i = 0; i < sending.length; ) {
    if (to.stopping()) return;
    let j = i + 1;
    for (let bytes = sending[i]!.size; j < sending.length && j - i < files && bytes + sending[j]!.size <= most; j++) bytes += sending[j]!.size;
    const pack = sending.slice(i, j);
    i = j;
    const took = await sendPack(to, pack, strict);
    // (one left, changed or gone as it was read: for the next gathering, not counted done)
    for (const e of pack) if (took.has(e.hash)) for (const f of of.get(e.hash)!) to.done(f.size);
  }
}

/// One pack sent, the hashes of what is there now said back. Its request meeting the other's connection gone, the first
/// time in a turn: sent again, of what it lacks then (what it took of the pack before is not sent again).
async function sendPack(to: Sending, pack: PackEntry[], strict: boolean): Promise<Set<string>> {
  const put = async (entries: PackEntry[]) => {
    const took: PackEntry[] = [];
    await to.putPack!(entries, packBytes(entries, strict, took, () => to.stopping()), strict);
    return took;
  };
  let took: PackEntry[];
  try {
    took = await put(pack);
  } catch (e) {
    if (!(e instanceof AskAgain)) throw e;
    took = [];
    let rest = pack;
    if (pack.length > 1) {
      const hashes = pack.map((f) => f.hash);
      const answer = await to.lacking(hashes, pack);
      const lacking = new Set<string>(Array.isArray(answer?.lacking) ? answer.lacking : hashes);
      rest = pack.filter((f) => lacking.has(f.hash));
      took = pack.filter((f) => !lacking.has(f.hash));
    }
    if (rest.length > 0) took.push(...(await put(rest)));
  }
  for (const f of took) to.took?.(f);
  return new Set(took.map((f) => f.hash));
}

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

const there = (path: string) => stat(path).then(() => true, () => false);

/// Of `hashes`, those not in `files` (a station taking another's files).
export async function lackingIn(files: string, hashes: string[]): Promise<string[]> {
  const held = await Promise.all(hashes.map((h) => there(join(files, h))));
  return hashes.filter((_, i) => !held[i]);
}

/// A file sent, taken into `files` by its hash: written beside, its bytes' hash checked as they come, then put in place;
/// one whose bytes are not what its name says (it changed as it was read) refused. `flush`: written out to the drive
/// before it is in place; not where its taker flushes once what it says it placed (`flushOnce`): on macOS a file's
/// flush is the whole drive's (F_FULLFSYNC), 70% of taking a small file (measured 2026-11-16: 7.5 ms with it, 2 ms
/// without), and it stalls all else writing to that disk.
export async function receiveFile(files: string, hash: string, bytes: Bytes, flush = true): Promise<void> {
  const path = join(files, hash);
  if (await there(path)) {
    for await (const _ of bytes) void _;
    return;
  }
  await mkdir(files, { recursive: true });
  const tmp = `${path}.${randomBytes(4).toString("hex")}.tmp`;
  const h = createHash("sha256");
  const f = await open(tmp, "w");
  try {
    for await (const piece of bytes) {
      h.update(piece);
      for (let done = 0; done < piece.length; ) done += (await f.write(piece, done, piece.length - done)).bytesWritten;
    }
    if (flush) await f.sync();
  } catch (e) {
    await f.close().catch(() => {});
    await rm(tmp, { force: true });
    throw e;
  }
  await f.close();
  if (h.digest("hex") !== hash) {
    await rm(tmp, { force: true });
    throw new Refused("changed: its bytes are not what its name says");
  }
  await rename(tmp, path);
}

/// Whether this machine writes out a file system at once (`flushOnce`); where it does not, each file is flushed as it
/// is taken.
export const flushesOnce = platform.flushing(".") !== null;

/// What was written to the file system holding `dir`, out on the drive: the system's `sync` (that file system alone on
/// Linux), then one file under `dir` flushed, the drive's own cache with it (F_FULLFSYNC on macOS). One for all the
/// files a placing took, before it says it placed them (handover.ts `#place`). macOS's sync(2) may return before all
/// is written (its man page says so), so there this is as much as the system gives short of a flush a file: taken
/// knowingly, as the station a chat came from keeps its room after it went, and a hand-over still coming as this
/// machine starts again is dropped (handover.ts `#load`, `boot`).
export async function flushOnce(dir: string): Promise<void> {
  const command = platform.flushing(dir);
  if (command === null) return;
  await run(command[0], command[1]);
  const f = await open(join(dir, "flushed"), "w");
  try {
    await f.sync();
  } finally {
    await f.close();
  }
}

/// A request with `bytes` after it.
export const sent = (request: Json, bytes: Bytes) => withBytes(request, bytes);
