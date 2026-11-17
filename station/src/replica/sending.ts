// What a gathering (carry.ts) names, sent to another station a bounded batch at a time, and taken there by its
// hash: what a station retired (retire.ts) and a chat handed over (handover.ts) both send their files by. Each session's
// list is read as it streams, what the other lacks asked of in batches (`lacking`, at most `most` hashes), each file it
// lacks sent (`put`), then the list itself; nothing of it is one object on the main thread. Where the other says it
// takes them so (`lacking`'s `pack`), what it lacks of a batch goes a pack at a time, in zstd (`packBytes`): a request
// a file was 252k requests in a row, 182 s between a VM and its own host, for a chat of 252k files (the drill of
// 2026-11-16).
import { execFile } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import { createReadStream } from "node:fs";
import { mkdir, open, readFile, rename, rm, stat } from "node:fs/promises";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { promisify } from "node:util";
import { type Bytes, Refused, withBytes } from "../mesh/bus.ts";
import { platform } from "../platform/index.ts";
import { AskAgain } from "../move/module.ts";
import { fileBytes, oneBytes } from "../mesh/files.ts";
import type { CarryIndex, Gathered } from "./carry.ts";
import { CHANGED, PACK_ENCODING, PACK_MAX_BYTES, PACK_MAX_FILES, type PackEntry, WENT, packBytes, there } from "./pack.ts";

export { PACK_ENCODING, PACK_MAX_BYTES, PACK_MAX_FILES, type PackEntry, lackingIn, packBytes, receivePack } from "./pack.ts";

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
