// What of station_task's directory sync (`dir`) is Node's on the source: the queue the station's bulk requests to other
// stations wait in (`Bulk`: a sync's packed pieces, a file's chunks), and, once a task ended, the patch of what its
// command changed in the mirror (`patchOf`, of the files bringBack fetched). How a sync goes, and all of it but those,
// is the MoonBit program's: the source's side (what the directory has, compared, packed and sent) in
// station/mb src/reader/dirsync_source.mbt, the target's (the mirror's manifest, the pieces unpacked, the plan applied)
// in src/reader/dirsync.mbt. What this file did of the sending before is test/dirsync-reference.ts, the tests'.
import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { chmod, lstat, mkdir, readFile, readlink, rm, symlink, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { promisify } from "node:util";

export const FILE = "100644";
export const EXEC = "100755";
export const LINK = "120000";
/// A sync request's pieces unpacked at most (the program's `max_raw`).
export const RAW = 16 * 1024 * 1024;
/// A request's packed pieces at most, after it: RAW, and what packing adds to what does not shrink.
export const PACKED = RAW + 1024 * 1024;

const run = promisify(execFile);

/// A file's content id as Git has it.
export function blobId(content: Buffer): string {
  return createHash("sha1").update(`blob ${content.length}\0`).update(content).digest("hex");
}

/// The station's bulk requests to other stations (a sync's contents, a file's chunks), one at a time, in the order
/// they came. What a station sends another waits in one queue with everything else it sends on the way (a relay's,
/// iroh's: first in, first out): with several syncs pushing at once that queue grew to ten seconds, and members'
/// devices, whose handshakes waited in it behind them, gave up connecting (2026-10-19, a station). One request at a time
/// keeps at most one request's worth (under 1 MiB) ahead of them.
export class Bulk {
  private last: Promise<unknown> = Promise.resolve();

  /// `f` once the request before it is answered (or failed).
  run<T>(f: () => Promise<T>): Promise<T> {
    const result = this.last.then(f, f);
    this.last = result.catch(() => undefined);
    return result;
  }
}

// ── the source: what a task changed in the mirror, as a patch ──

/// A patch from what the mirror had (`old` ids, taken from `dir` or its Git objects) to what a command left there
/// (`after`, null for a file it removed); null when git is not there. Paths as `git apply` takes them in `dir`
/// (`prefix`: dir's place in its work tree). `missing`: files whose old content was not found (left out of the patch).
export async function patchOf(
  dir: string,
  prefix: string,
  scratch: string,
  changes: { path: string; old: string; mode: string; after: Buffer | null; afterMode: string | null }[],
): Promise<{ patch: string; missing: string[] } | null> {
  try {
    await run("git", ["--version"]);
  } catch {
    return null;
  }
  const missing: string[] = [];
  // Every file of it off the station's thread: written and read there one by one, a task's 23 files brought back held
  // the station 3 s on a station short of memory (2026-11-03), a message sent meanwhile waiting.
  await mkdir(scratch, { recursive: true });
  try {
    const g = (args: string[]) => run("git", ["-C", scratch, "-c", "core.autocrlf=false", "-c", "core.symlinks=true", "-c", "core.filemode=true", ...args], { maxBuffer: 1 << 30 });
    await g(["init", "-q"]);
    const put = async (path: string, content: Buffer, mode: string) => {
      const abs = join(scratch, ...path.split("/"));
      await mkdir(dirname(abs), { recursive: true });
      await rm(abs, { force: true });
      if (mode === LINK) await symlink(content.toString(), abs);
      else {
        await writeFile(abs, content);
        await chmod(abs, mode === EXEC ? 0o755 : 0o644);
      }
    };
    const kept = [];
    for (const c of changes) {
      let before: Buffer | null = null;
      const abs = join(dir, ...c.path.split("/"));
      try {
        const st = await lstat(abs);
        const local = st.isSymbolicLink() ? Buffer.from(await readlink(abs)) : st.isFile() ? await readFile(abs) : null;
        if (local !== null && blobId(local) === c.old) before = local;
      } catch {}
      if (before === null) {
        try {
          const { stdout } = await run("git", ["-C", dir, "cat-file", "blob", c.old], { encoding: "buffer", maxBuffer: 1 << 30 });
          before = stdout as unknown as Buffer;
        } catch {}
      }
      if (before === null) {
        missing.push(c.path);
        continue;
      }
      await put(c.path, before, c.mode);
      kept.push(c);
    }
    await g(["add", "-A"]);
    for (const c of kept) {
      if (c.after === null) await rm(join(scratch, ...c.path.split("/")), { force: true });
      else await put(c.path, c.after, c.afterMode ?? c.mode);
    }
    const { stdout } = await g(["diff", "--binary", `--src-prefix=a/${prefix}`, `--dst-prefix=b/${prefix}`]);
    return { patch: stdout, missing };
  } finally {
    await rm(scratch, { recursive: true, force: true });
  }
}
