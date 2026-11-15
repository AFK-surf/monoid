// What a gathering (carry-worker.ts) names, sent to another station a bounded batch at a time, and taken there by its
// hash: what a station retired (retire.ts) and a chat handed over (handover.ts) both send their files by. Each session's
// list is read as it streams, what the other lacks asked of in batches (`lacking`, at most `most` hashes), each file it
// lacks sent (`put`), then the list itself; nothing of it is one object on the main thread.
import { createHash, randomBytes } from "node:crypto";
import { createReadStream } from "node:fs";
import { mkdir, open, readFile, rename, rm, stat } from "node:fs/promises";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { type Bytes, Refused, withBytes } from "../mesh/bus.ts";
import { AskAgain } from "../move/module.ts";
import { fileBytes, oneBytes } from "../mesh/files.ts";
import type { CarryIndex, Gathered } from "./carry-worker.ts";

type Json = any;

/// How a sending reaches the other station and says how far it went.
export type Sending = {
  /// Asks of the other station what of `hashes` it lacks (its answer's `lacking`); `files`: each with where it is put
  /// and how big (a station that keeps a copy of the room says which it has in place already).
  lacking(hashes: string[], files: { hash: string; path: string; size: number; mtimeMs?: number; room?: string }[]): Promise<Json>;
  /// Sends it one file by its hash (`path`: where it is here; "" for a list or the index).
  put(hash: string, bytes: Bytes, path: string, size: number): Promise<Json>;
  /// The most hashes one `lacking` asks of.
  most: number;
  /// Whether to stop between files (a cancel, the process closing).
  stopping(): boolean;
  /// The bytes the index names, as it is read (`total`), and `done` of them as each goes (or was there).
  total(bytes: number): void;
  done(bytes: number): void;
};

/// What the gathering `g` names that the other station lacks, sent: each session's list as it streams, then the list
/// itself (`strict`); the bundles; the index last (with `jobs` in it), its hash said back (null: stopped, or not
/// `strict`). A file that changed since it was gathered is refused there: left for the next gathering while the chats
/// work, gathered again (the step tried again, thrown) once they are held (`strict`). The agent home's list is one more.
/// `indexed`: the index put (its hash said back) where not `strict` too, so what was sent can be placed already.
export async function sendGathered(g: Gathered, to: Sending, strict: boolean, jobs: unknown[] = [], indexed = false): Promise<string | null> {
  const index = JSON.parse(await readFile(g.index, "utf8")) as CarryIndex;
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
  for (const f of batch) {
    if (to.stopping()) return;
    if (lacking.delete(f.hash)) {
      let size = 0;
      try {
        size = (await stat(f.path)).size;
      } catch {
        // (gone since it was gathered: left for the next gathering while the chats work; once they are held the
        // gathering is made again, so that the other station is sent all its lists name)
        if (strict) throw new Error("a file went as it was sent: gathered again");
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
          if (strict) throw new Error("a file went as it was sent: gathered again");
          continue;
        }
        if (!(e instanceof Refused && /changed/.test(e.message)) && !/got shorter/.test((e as Error).message)) throw e;
        if (strict) throw new Error("a file changed as it was sent: gathered again");
        continue;
      }
    }
    to.done(f.size);
  }
}

const there = (path: string) => stat(path).then(() => true, () => false);

/// Of `hashes`, those not in `files` (a station taking another's files).
export async function lackingIn(files: string, hashes: string[]): Promise<string[]> {
  const held = await Promise.all(hashes.map((h) => there(join(files, h))));
  return hashes.filter((_, i) => !held[i]);
}

/// A file sent, taken into `files` by its hash: written beside, its bytes' hash checked as they come, then put in place;
/// one whose bytes are not what its name says (it changed as it was read) refused.
export async function receiveFile(files: string, hash: string, bytes: Bytes): Promise<void> {
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
    await f.sync();
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

/// A request with `bytes` after it.
export const sent = (request: Json, bytes: Bytes) => withBytes(request, bytes);
