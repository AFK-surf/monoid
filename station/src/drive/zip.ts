// A folder put into a zip, for a member to send it in a chat as one file (drive.ts `stage`) or to download it
// (drive.ts `zip`): every file under it, deflated, named by its path in the folder (under the folder's own name), with
// its time. Links are not followed, and what `skip` names (the station's own data, uploads not finished) is left out.
// No zip64: at most `most` bytes read in all, which the caller keeps well under 4 GB, and at most MAX_ENTRIES entries.
// The folder is read as `fs` reaches it (fs.ts: through still.fail Helper for one macOS keeps from the station); the
// zip is the station's own file.
//
// Nothing of it waits on the station's thread, and its memory is a chunk's whatever the files' sizes (a file was read
// whole into the heap and deflated on the main thread): each file is read a chunk at a time (`Fs` `readStream`, else
// `read` by parts), its CRC rolled on and its chunks deflated by zlib on libuv's threads, written as they come out
// behind its header, which is filled in once the file is read. One that deflate does not make smaller is stored as it
// is, as before: kept where it was one chunk, else read again, and written over what was deflated.
// The walk is the folder's as `fs` reaches it, so not `ops/walk.ts` (which reads the disk itself), but bounded as it
// is: no deeper than MAX_DEPTH, no more than MAX_ENTRIES, no recursion.
import { crc32, createDeflateRaw } from "node:zlib";
import { open, type FileHandle } from "node:fs/promises";
import { pipeline } from "node:stream/promises";
import { basename, join } from "node:path";
import { type Fs, direct } from "./fs.ts";

export class TooBig extends Error {}

/// What one read of a file gives at most.
export const ZIP_CHUNK = 256 * 1024;
/// Folders below the top gone into at most; one deeper makes the zip too big to make.
export const MAX_DEPTH = 64;
/// Entries at most (a zip without zip64 counts them in 16 bits).
export const MAX_ENTRIES = 65_535;

type Entry = { name: Buffer; crc: number; size: number; packed: number; method: number; at: number; time: number; date: number };

/// A time as DOS has it (2-second steps, local time, 1980 through 2107).
function dos(ms: number): { time: number; date: number } {
  // Both bounds are local too: midnight UTC can belong to another year here.
  const first = new Date(1980, 0, 1).getTime();
  const last = new Date(2108, 0, 1).getTime() - 1;
  const d = new Date(Math.max(first, Math.min(ms, last)));
  return {
    time: (d.getHours() << 11) | (d.getMinutes() << 5) | Math.floor(d.getSeconds() / 2),
    date: ((d.getFullYear() - 1980) << 9) | ((d.getMonth() + 1) << 5) | d.getDate(),
  };
}

/// A file's bytes a chunk at a time, as `fs` reads it.
async function* chunksOf(fs: Fs, path: string): AsyncGenerator<Buffer> {
  if (fs.readStream) {
    yield* fs.readStream(path, ZIP_CHUNK);
    return;
  }
  for (let at = 0; ; ) {
    const { bytes } = await fs.read(path, at, ZIP_CHUNK);
    if (bytes.length > 0) yield bytes;
    if (bytes.length < ZIP_CHUNK) return;
    at += bytes.length;
  }
}

async function writeAt(out: FileHandle, b: Buffer, at: number): Promise<void> {
  let done = 0;
  while (done < b.length) done += (await out.write(b, done, b.length - done, at + done)).bytesWritten;
}

/// Writes `dir` as a zip at `to` (made new; it must not be there). Answers the zip's size.
export async function zipFolder(dir: string, to: string, most: number, skip: (path: string, name: string) => Promise<boolean>, fs: Fs = direct): Promise<number> {
  const out = await open(to, "wx");
  let at = 0;
  let read = 0;
  const entries: Entry[] = [];
  const write = async (b: Buffer) => {
    await writeAt(out, b, at);
    at += b.length;
  };
  const header = (e: Entry) => {
    const h = Buffer.alloc(30);
    h.writeUInt32LE(0x04034b50, 0);
    h.writeUInt16LE(20, 4);
    h.writeUInt16LE(0x0800, 6); // names in UTF-8
    h.writeUInt16LE(e.method, 8);
    h.writeUInt16LE(e.time, 10);
    h.writeUInt16LE(e.date, 12);
    h.writeUInt32LE(e.crc, 14);
    h.writeUInt32LE(e.packed, 18);
    h.writeUInt32LE(e.size, 22);
    h.writeUInt16LE(e.name.length, 26);
    h.writeUInt16LE(0, 28);
    return h;
  };
  const entry = (name: string, mtime: number): Entry => {
    if (entries.length >= MAX_ENTRIES) throw new TooBig();
    return { name: Buffer.from(name, "utf8"), crc: 0, size: 0, packed: 0, method: 0, at, ...dos(mtime) };
  };
  const folder = async (name: string, mtime: number) => {
    const e = entry(name, mtime);
    await write(header(e));
    await write(e.name);
    entries.push(e);
  };
  /// A file's bytes counted against `most` as they are read, its CRC rolled on; `first` keeps them while there is
  /// only one chunk.
  const counted = async function* (path: string, file: { crc: number; size: number; first: Buffer | null }) {
    for await (const chunk of chunksOf(fs, path)) {
      read += chunk.length;
      if (read > most) throw new TooBig();
      file.crc = crc32(chunk, file.crc);
      file.first = file.size === 0 ? chunk : null;
      file.size += chunk.length;
      yield chunk;
    }
  };
  const file = async (name: string, path: string, mtime: number) => {
    const e = entry(name, mtime);
    const data = at + 30 + e.name.length;
    // The header written once the file is read; its place kept.
    at = data;
    const before = read;
    const got = { crc: 0, size: 0, first: null as Buffer | null };
    let packed = 0;
    await pipeline(counted(path, got), createDeflateRaw(), async (deflated: AsyncIterable<Buffer>) => {
      for await (const chunk of deflated) {
        await writeAt(out, chunk, data + packed);
        packed += chunk.length;
      }
    });
    e.crc = got.crc >>> 0;
    e.size = got.size;
    if (got.size > 0 && packed < got.size) {
      e.method = 8;
      e.packed = packed;
    } else {
      // Not made smaller (or empty): stored as it is, over what was deflated.
      await out.truncate(data);
      if (got.first !== null) await writeAt(out, got.first, data);
      else if (got.size > 0) {
        read = before;
        const again = { crc: 0, size: 0, first: null as Buffer | null };
        for await (const chunk of counted(path, again)) await writeAt(out, chunk, data + again.size - chunk.length);
        e.crc = again.crc >>> 0;
        e.size = again.size;
      }
      e.packed = e.size;
    }
    await writeAt(out, header(e), e.at);
    await writeAt(out, e.name, e.at + 30);
    at = data + e.packed;
    entries.push(e);
  };
  try {
    const top = basename(dir) || "folder";
    const s = await fs.lstat(dir);
    await folder(`${top}/`, s.mtimeMs);
    // Depth first, each folder's names in order, as a recursion would go: a stack of the folders under way.
    const stack: { path: string; name: string; names: string[]; next: number }[] = [{ path: dir, name: top, names: (await fs.names(dir)).sort(), next: 0 }];
    while (stack.length > 0) {
      const f = stack.at(-1)!;
      if (f.next >= f.names.length) {
        stack.pop();
        continue;
      }
      const child = f.names[f.next++]!;
      const full = join(f.path, child);
      if (await skip(full, child)) continue;
      const c = await fs.lstat(full).catch(() => null);
      if (c === null || c.link) continue;
      const inZip = `${f.name}/${child}`;
      if (c.dir) {
        if (stack.length > MAX_DEPTH) throw new TooBig();
        await folder(`${inZip}/`, c.mtimeMs);
        stack.push({ path: full, name: inZip, names: (await fs.names(full)).sort(), next: 0 });
      } else if (c.file) {
        if (read + c.size > most) throw new TooBig();
        await file(inZip, full, c.mtimeMs);
      }
    }
    const start = at;
    for (const e of entries) {
      const c = Buffer.alloc(46);
      c.writeUInt32LE(0x02014b50, 0);
      c.writeUInt16LE(0x031e, 4); // made by Unix, 3.0
      c.writeUInt16LE(20, 6);
      c.writeUInt16LE(0x0800, 8);
      c.writeUInt16LE(e.method, 10);
      c.writeUInt16LE(e.time, 12);
      c.writeUInt16LE(e.date, 14);
      c.writeUInt32LE(e.crc, 16);
      c.writeUInt32LE(e.packed, 20);
      c.writeUInt32LE(e.size, 24);
      c.writeUInt16LE(e.name.length, 28);
      const isFolder = e.name[e.name.length - 1] === 0x2f;
      c.writeUInt32LE((((isFolder ? 0o40755 : 0o100644) << 16) | (isFolder ? 0x10 : 0)) >>> 0, 38);
      c.writeUInt32LE(e.at, 42);
      await write(c);
      await write(e.name);
    }
    const end = Buffer.alloc(22);
    end.writeUInt32LE(0x06054b50, 0);
    end.writeUInt16LE(entries.length, 8);
    end.writeUInt16LE(entries.length, 10);
    end.writeUInt32LE(at - start, 12);
    end.writeUInt32LE(start, 16);
    await write(end);
    await out.sync();
    return at;
  } finally {
    await out.close();
  }
}
