// Cold storage for owned session workspaces and runtime transcripts (the Rust station's archive.rs). The caller holds the
// room's lock and has stopped its actor. Originals are removed only after a complete, checksummed archive has been read
// back.
//
// The files are the Rust's, byte for byte in format, so either station restores what the other packed: a workspace is
// `workspace.tar.zst` in its room (a GNU tar as the tar crate writes it, zstd level 3 with a checksum), a transcript
// `<file>.jsonl.zst` beside where it was (since 2026-11 in segments with a table, made and read back by the MoonBit program,
// sessions/packed-mb.ts, as station/test/reference/packed.ts reads them); the same temporaries (`.writing`, `.restoring`, `workspace.retiring`,
// `workspace.restored-old`), the same `archive.lock` and `<file>.jsonl.archive-lock`, the same `workspace-locks.json`
// and the git worktree `locked` files with the same marker.
//
// None of their bytes are on the station's thread or in its heap: a transcript is put away and written back by the
// MoonBit program (sessions/packed-mb.ts, `--builder packed`), and so is a workspace, whose tar the shell writes and reads
// a block at a time (client/shell `tar.pack`, `tar.unpack`, `tar.file`: what this file did before is
// station/test/reference/workspace-archive.ts, which station/test/mb-packed.test.ts holds them to). This keeps the locks,
// the worktrees' and the renames that put what the program made in place.
//
// The lock: Node has no flock; the native addon's (native/mesh/src/local.rs) is taken, as the Rust takes it. Without the
// addon (tests), the lock files are made where the Rust makes them but the lock itself is held within
// this process (one station at a time works on a data directory; only an overlap at a handover would see both).
import { loadMesh } from "../mesh/native.ts";
import { chmod, copyFile, lstat, mkdir, open, readFile, readdir, readlink, realpath, rm, stat, unlink } from "node:fs/promises";
import { basename, dirname, isAbsolute, join, relative, resolve } from "node:path";
import { renameRetrying, type RenameRetry } from "../ops/files.ts";
import { log } from "../ops/log.ts";
import { clean, inside, segments } from "../ops/paths.ts";
import { walkBounded } from "../ops/walk.ts";
import { link as symlinkOrStandIn } from "../ops/links.ts";
import { platform } from "../platform/index.ts";
import { PackAborted, packedProgram, runPackedOnce } from "./packed-mb.ts";

// ── paths ──────────────────────────────────────────────────────────────────────────────────────────────────────────

/// Path::with_extension: the file name's extension (after its last dot, not a leading one) replaced, or added.
export function withExtension(path: string, ext: string): string {
  const name = basename(path);
  const dot = name.lastIndexOf(".");
  const stem = dot > 0 ? name.slice(0, dot) : name;
  return join(dirname(path), ext === "" ? stem : `${stem}.${ext}`);
}

/// Path::extension.
const extension = (path: string): string | null => {
  const name = basename(path);
  const dot = name.lastIndexOf(".");
  return dot > 0 ? name.slice(dot + 1) : null;
};

export const workspaceArchive = (room: string) => join(room, "workspace.tar.zst");

/// Where a file is once put away.
export const packed = (path: string) => `${path}.zst`;

// ── the lock ───────────────────────────────────────────────────────────────────────────────────────────────────────

const held = new Map<string, Promise<void>>();

let addon: ((path: string) => Promise<{ release(): void }>) | null | undefined;
function nativeLock() {
  if (addon === undefined) {
    try {
      const mesh = loadMesh();
      addon = (path: string) => mesh.fileLock(path);
    } catch {
      addon = null;
    }
  }
  return addon;
}

/// file_lock: the lock file made (0600, never truncated) and the lock taken, in turn with whoever else in this process
/// asked for it. The returned function lets it go.
async function fileLock(path: string): Promise<() => void> {
  const before = held.get(path) ?? Promise.resolve();
  let release!: () => void;
  const mine = new Promise<void>((resolve) => (release = resolve));
  const tail = before.then(() => mine);
  held.set(path, tail);
  const done = () => {
    release();
    if (held.get(path) === tail) held.delete(path);
  };
  await before;
  try {
    // Across processes too (a handover's two, a Rust station's), with the native addon's flock, when it is there.
    const native = nativeLock();
    if (native === null) {
      await (await open(path, "a", 0o600)).close();
      return done;
    }
    const held = await native(path);
    return () => {
      held.release();
      done();
    };
  } catch (error) {
    done();
    throw error;
  }
}

/// A room's lock (`archive.lock` in it): held while its workspace is packed, restored, read from its archive or deleted.
export const lock = (room: string) => fileLock(join(room, "archive.lock"));

/// `f` run under a room's lock.
export async function withLock<T>(room: string, f: () => Promise<T>): Promise<T> {
  const release = await lock(room);
  try {
    return await f();
  } finally {
    release();
  }
}

async function writeAll(file: import("node:fs/promises").FileHandle, chunk: Buffer) {
  for (let at = 0; at < chunk.length; ) at += (await file.write(chunk, at, chunk.length - at)).bytesWritten;
}

/// A directory's entries made durable (File::open(dir).sync_all()), where a directory syncs (on Windows Node's is
/// refused, EPERM: NTFS journals a directory's entries itself).
async function syncDir(dir: string) {
  if (!platform.syncsDirectories) return;
  const handle = await open(dir, "r");
  try {
    await handle.sync();
  } finally {
    await handle.close();
  }
}

const exists = async (path: string) => {
  try {
    await stat(path);
    return true;
  } catch {
    return false;
  }
};
const lstatOrNull = async (path: string) => {
  try {
    return await lstat(path);
  } catch {
    return null;
  }
};

/// `rm -r` that also takes directories their owner cannot write to (a Go module cache makes all of its own read-only):
/// refused once, everything under `path` is given its owner's write (and a directory's read and search) and it goes.
export async function removeTree(path: string, opts: { force?: boolean } = {}): Promise<void> {
  try {
    await rm(path, { recursive: true, force: opts.force ?? false });
  } catch (error) {
    const code = (error as NodeJS.ErrnoException).code;
    if (code !== "EACCES" && code !== "EPERM") throw error;
    await ownerWritable(path);
    await rm(path, { recursive: true, force: opts.force ?? false });
  }
}

/// (What goes meanwhile is passed over: the refused `rm` goes on removing the rest after it rejects, a sibling of what
/// it was refused at gone under this walk, 2026-11-16, a test's read-only directory beside a project.)
async function ownerWritable(path: string): Promise<void> {
  const there = await lstatOrNull(path);
  if (!there || there.isSymbolicLink()) return;
  const gone = (error: NodeJS.ErrnoException) => {
    if (error.code !== "ENOENT") throw error;
  };
  const need = there.isDirectory() ? 0o700 : 0o200;
  if ((there.mode & need) !== need) await chmod(path, (there.mode | need) & 0o7777).catch(gone);
  if (!there.isDirectory()) return;
  const names = await readdir(path).catch((error: NodeJS.ErrnoException) => (gone(error), [] as string[]));
  for (const name of names) await ownerWritable(join(path, name));
}

// ── transcripts ────────────────────────────────────────────────────────────────────────────────────────────────────

/// Compress a transcript in place, leaving its filename discoverable as <original>.zst. Retry after a crash safely: an
/// original still there always wins over the old compressed copy.
export const packFile = (path: string) => packFileIf(path, () => true);

export async function packFileIf(path: string, ready: () => boolean): Promise<void> {
  const release = await fileLock(withExtension(path, "jsonl.archive-lock"));
  try {
    if (!(await lstatOrNull(path))?.isFile()) {
      // Only the copy left: read through whole, its checksums verified.
      if (await exists(packed(path))) await packedProgram().ask("check", { path: packed(path) });
      return;
    }
    const dest = packed(path);
    const temp = withExtension(dest, "zst.writing");
    try {
      // In segments into `temp`, read back and found to be the transcript still, byte for byte.
      await packedProgram().ask("pack", { path, temp });
      if (!ready()) return;
      await renameRetrying(temp, dest);
      await syncDir(dirname(dest));
      await unlink(path);
    } finally {
      await rm(temp, { force: true });
    }
  } finally {
    release();
  }
}

/// A transcript put away before it was in segments, or with its last segment stored as it is, put away again as
/// `packFile` puts one away now: whether it was (not where it is in segments already).
export async function segmentFile(path: string): Promise<boolean> {
  const release = await fileLock(withExtension(path, "jsonl.archive-lock"));
  try {
    const source = packed(path);
    if ((await exists(path)) || !(await exists(source))) return false;
    const temp = withExtension(source, "zst.writing");
    try {
      // (what it holds and what the copy holds the same, by their SHA-256)
      const { segmented } = await packedProgram().ask<{ segmented: boolean }>("segment", { path, source, temp });
      if (!segmented) return false;
      await renameRetrying(temp, source);
      await syncDir(dirname(source));
      return true;
    } finally {
      await rm(temp, { force: true });
    }
  } finally {
    release();
  }
}

export async function restoreFile(path: string): Promise<void> {
  const release = await fileLock(withExtension(path, "jsonl.archive-lock"));
  try {
    const source = packed(path);
    if (!(await exists(source))) return;
    if (await exists(path)) return; // Never overwrite a runtime's newer transcript.
    const temp = withExtension(path, "jsonl.restoring");
    try {
      // Written whole into `temp` (0600, on disk), every frame whole and checksummed.
      await packedProgram().ask("restore", { source, temp });
      await renameRetrying(temp, path);
      await syncDir(dirname(path));
      await unlink(source);
    } finally {
      await rm(temp, { force: true });
    }
  } finally {
    release();
  }
}

/// Logical JSONL names under `dir`, including files whose raw bytes have been put away, each once, off the station's
/// thread: walked as every walk is (ops/walk.ts `walkBounded`: on its file system, no link followed, bounded, yielding).
export async function jsonlFilesSoon(dir: string, out: string[]): Promise<void> {
  const seen = new Set(out);
  await walkBounded(dir, (entry) => {
    if (entry.depth === 0 || !entry.file) return;
    const logical = extension(entry.path) === "zst" ? withExtension(entry.path, "") : entry.path;
    if (extension(logical) === "jsonl" && !seen.has(logical)) {
      seen.add(logical);
      out.push(logical);
    }
  }, {
    onError: (_path, error) => {
      if (error.code !== "ENOENT") throw error;
    },
  });
}

// ── git worktrees ──────────────────────────────────────────────────────────────────────────────────────────────────

async function lockWorktrees(dir: string, marker: string, locks: string[]): Promise<void> {
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name);
    if (entry.name === ".git") {
      if (!entry.isFile()) continue;
      const said = (await readFile(path, "utf8")).trim();
      if (!said.startsWith("gitdir: ")) continue;
      const gitdir = await realpath(resolve(dir, said.slice("gitdir: ".length))).catch((error: NodeJS.ErrnoException) => {
        if (error.code === "ENOENT") return null;
        throw error;
      });
      // Its repository has no record of it any more (pruned, removed): nothing to lock, and the rest is packed all the
      // same. One such worktree left a chat's 1.4G unpacked (2026-10-23).
      if (gitdir === null) continue;
      const locked = join(gitdir, "locked");
      let file;
      try {
        file = await open(locked, "wx");
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
        const there = await readFile(locked, "utf8").catch(() => null);
        if (there === marker && !locks.includes(locked)) locks.push(locked);
        continue;
      }
      try {
        await writeAll(file, Buffer.from(marker));
        await file.sync();
      } finally {
        await file.close();
      }
      locks.push(locked);
    } else if (entry.isDirectory()) {
      await lockWorktrees(path, marker, locks);
    }
  }
}

export const ARCHIVE_WORKTREE_LOCK_PREFIX = "still.fail archived workspace: ";

const markerOf = (room: string) => `${ARCHIVE_WORKTREE_LOCK_PREFIX}${room}\n`;

export async function unlockWorktrees(room: string): Promise<void> {
  const path = join(room, "workspace-locks.json");
  if (!(await exists(path))) return;
  const locks = JSON.parse(await readFile(path, "utf8")) as string[];
  for (const locked of locks) {
    if ((await readFile(locked, "utf8").catch(() => null)) === markerOf(room)) await unlink(locked);
  }
  await unlink(path);
}

/// Collects worktree registration directories (`<common>/worktrees/<name>`) owned by a session room:
/// from `.git` files under the room (walked via `walkBounded`) and from `workspace-locks.json` for packed rooms.
export async function collectWorktreeRegistrations(room: string): Promise<string[]> {
  const found = new Set<string>();
  const add = async (candidate: string) => {
    const resolved = await realpath(candidate).catch(() => null);
    if (resolved === null) return;
    if (basename(dirname(resolved)) !== "worktrees") return;
    found.add(resolved);
  };
  const gitFiles: string[] = [];
  await walkBounded(room, (entry) => {
    if (entry.file && entry.name === ".git") gitFiles.push(entry.path);
  }, { onError: () => {} });
  for (const file of gitFiles) {
    const said = (await readFile(file, "utf8").catch(() => "")).trim();
    if (!said.startsWith("gitdir: ")) continue;
    await add(resolve(dirname(file), said.slice("gitdir: ".length)));
  }
  const locksPath = join(room, "workspace-locks.json");
  const locksText = await readFile(locksPath, "utf8").catch(() => null);
  if (locksText !== null) {
    try {
      const locks = JSON.parse(locksText) as unknown;
      if (Array.isArray(locks)) {
        for (const locked of locks) {
          if (typeof locked === "string" && locked !== "") await add(dirname(locked));
        }
      }
    } catch {}
  }
  return [...found];
}

/// Removes only the exact worktree registration directories in `adminDirs` that belong to `roomPaths`,
/// whose target `.git` file no longer exists, and that have no `locked` file remaining.
export async function removeWorktreeRegistrations(adminDirs: readonly string[], roomPaths: readonly string[]): Promise<string[]> {
  const rooms = roomPaths.map((r) => clean(r));
  const removed: string[] = [];
  for (const adminDir of adminDirs) {
    try {
      if (basename(dirname(adminDir)) !== "worktrees") continue;
      const st = await lstat(adminDir).catch(() => null);
      if (st === null || !st.isDirectory() || st.isSymbolicLink()) continue;
      if (await lstat(join(adminDir, "locked")).then(() => true, () => false)) continue;
      const rawTarget = (await readFile(join(adminDir, "gitdir"), "utf8").catch(() => "")).trim();
      if (rawTarget === "" || !isAbsolute(rawTarget)) continue;
      const target = clean(rawTarget);
      if (!rooms.some((r) => inside(target, r))) continue;
      if (await lstat(target).then(() => true, () => false)) continue;
      await rm(adminDir, { recursive: true, force: true });
      removed.push(adminDir);
    } catch (error) {
      log.warn("hub", "worktree registration not removed", { path: adminDir, error: (error as Error).message });
    }
  }
  return removed;
}

// ── workspaces ─────────────────────────────────────────────────────────────────────────────────────────────────────

export const packWorkspace = (room: string) => packWorkspaceIf(room, () => true);

/// How long moving a whole workspace directory aside waits for a lock to clear (1.55 s in all): on Windows an agent's
/// process just stopped (`evict`), a scanner or the indexer keeps a handle in it a moment after (0.1.10630: EPERM 90 ms
/// after the eviction).
export const WORKSPACE_RENAME_BACKOFF = [50, 100, 200, 400, 800] as const;

export async function packWorkspaceIf(
  room: string,
  ready: () => boolean,
  opts?: Omit<RenameRetry, "backoff"> & { signal?: AbortSignal },
): Promise<void> {
  if (opts?.signal?.aborted) return;
  const archive = workspaceArchive(room);
  if (await exists(archive)) return;
  const workspace = join(room, "workspace");
  if (!(await stat(workspace).catch(() => null))?.isDirectory()) return;
  const temp = join(room, "workspace.tar.zst.writing");
  try {
    const locksPath = join(room, "workspace-locks.json");
    const locks: string[] = (await exists(locksPath)) ? JSON.parse(await readFile(locksPath, "utf8")) : [];
    // Keep registered worktrees out of `git worktree prune` while their .git files are inside the archive.
    let locked: unknown = null;
    await lockWorktrees(workspace, markerOf(room), locks).catch((e) => (locked = e ?? new Error("worktrees not locked")));
    const saved = await open(locksPath, "w");
    try {
      await writeAll(saved, Buffer.from(JSON.stringify(locks)));
      await saved.sync();
    } finally {
      await saved.close();
    }
    if (locked !== null) throw locked;
    if (opts?.signal?.aborted || !ready()) {
      await unlockWorktrees(room);
      return;
    }
    // Into `temp`, every entry read back to the end of the zstd stream and its checksum, and the workspace found as it
    // was before (each path's size and modification time) before any original is touched.
    try {
      await runPackedOnce("workspace.pack", { dir: workspace, out: temp }, { background: true, signal: opts?.signal });
    } catch (error) {
      await unlockWorktrees(room).catch(() => {});
      if (opts?.signal?.aborted || error instanceof PackAborted) return;
      throw error;
    }
    if (opts?.signal?.aborted || !ready()) {
      await unlockWorktrees(room);
      return;
    }
    await renameRetrying(temp, archive, opts);
    await syncDir(room);
    const retiring = join(room, "workspace.retiring");
    if (await exists(retiring)) throw new Error("an earlier workspace retirement needs restoration");
    try {
      await renameRetrying(workspace, retiring, { ...opts, backoff: WORKSPACE_RENAME_BACKOFF });
    } catch (error) {
      // The workspace is still whole where it was: the archive goes again, or the next round would find it, take the
      // workspace for packed (the first line here) and never retire it.
      await rm(archive, { force: true }).catch(() => {});
      await unlockWorktrees(room).catch(() => {});
      throw error;
    }
    await mkdir(workspace);
    await chmod(workspace, (await stat(retiring)).mode & 0o7777);
    await removeTree(retiring);
  } finally {
    await rm(temp, { force: true });
  }
}

/// Links the machine refused while the restored tree was being made (Windows without the privilege, the shell's
/// `tar.unpack` says them): by their path in it, their target as written. Made once the tree is at its final path
/// (restoreWorkspace), where what stands in for them (a junction's absolute target, a copy) stays right; a path written
/// again later is no longer one.
type Refused = Map<string, string>;

/// Copy files created since the snapshot into the restored tree. Originals stay intact until the final swap, so an
/// interrupted/failed restoration can be retried without discarding new files or the archive.
async function overlay(source: string, dest: string, refused: Refused): Promise<void> {
  // The archive's directories come back with their modes, a read-only one too: written into for the overlay only.
  const mode = (await stat(dest)).mode & 0o7777;
  if ((mode & 0o700) !== 0o700) await chmod(dest, mode | 0o700);
  try {
    await overlayEntries(source, dest, refused);
  } finally {
    if ((mode & 0o700) !== 0o700) await chmod(dest, mode);
  }
}

async function overlayEntries(source: string, dest: string, refused: Refused): Promise<void> {
  for (const entry of await readdir(source, { withFileTypes: true })) {
    // A Unix domain socket is a running program's endpoint, left out of the archive as it is of the overlay.
    if (entry.isSocket()) continue;
    const from = join(source, entry.name);
    const into = join(dest, entry.name);
    const there = await lstatOrNull(into);
    refused.delete(into);
    if (entry.isDirectory()) {
      if (there && !there.isDirectory()) throw new Error(`restore path conflict: ${into}`);
      await mkdir(into, { recursive: true });
      await overlay(from, into, refused);
    } else {
      if (there?.isDirectory()) throw new Error(`restore path conflict: ${into}`);
      if (there) await unlink(into);
      if (entry.isSymbolicLink()) {
        const target = await readlink(from);
        if ((await symlinkOrStandIn(target, into, {})) === "refused") refused.set(into, target);
      } else if (entry.isFile()) await copyFile(from, into);
      else throw new Error(`cannot restore special file ${from}`);
    }
  }
}

const isDir = async (path: string) => (await stat(path).catch(() => null))?.isDirectory() ?? false;

export async function restoreWorkspace(room: string): Promise<void> {
  const archive = workspaceArchive(room);
  if (!(await exists(archive))) return unlockWorktrees(room);
  const stage = join(room, "workspace.restoring");
  if (await exists(stage)) await removeTree(stage);
  await mkdir(stage);
  await chmod(stage, 0o700);
  const refused: Refused = new Map();
  try {
    // Made in `stage` by the shell (as the tar crate's Archive::unpack with its permissions), read to its checksum.
    const made = await packedProgram().ask<{ refused: [string, string][] }>("workspace.unpack", { path: archive, dest: stage });
    for (const [path, target] of made.refused) refused.set(path, target);
  } catch (error) {
    throw new Error(`restoring the archived workspace: ${(error as Error).message}`, { cause: error });
  }
  const workspace = join(room, "workspace");
  const retiring = join(room, "workspace.retiring");
  const old = join(room, "workspace.restored-old");
  for (const live of [retiring, old, workspace]) {
    if (await isDir(live)) await overlay(live, stage, refused);
  }
  if (await exists(old)) await removeTree(old);
  if (await exists(workspace)) await renameRetrying(workspace, old, { backoff: WORKSPACE_RENAME_BACKOFF });
  await renameRetrying(stage, workspace, { backoff: WORKSPACE_RENAME_BACKOFF });
  // The links refused on the way, at their final path now: a junction or a copy stands in (a target that is not
  // there, a dangling link, leaves nothing to stand in for: the link is not restored).
  for (const [path, target] of refused) {
    const at = join(workspace, relative(stage, path));
    if (!(await lstatOrNull(at))) await symlinkOrStandIn(target, at, { junction: true, copy: true });
  }
  await syncDir(room);
  // Everything is now back at its original path. Any interrupted deletion is harmless on the next restore.
  if (await exists(retiring)) await removeTree(retiring);
  if (await exists(old)) await removeTree(old);
  await unlink(archive);
  await readingsGone(room);
  await unlockWorktrees(room);
}

/// What an archived workspace keeps once it has been archived long enough: the files sent in its chat (`uploads/`), out
/// of its archive and on the disk again; the rest of it is removed, packed or not, and its worktrees are let go (`git
/// worktree prune` cleans them up). The caller holds the room's lock. The archive goes only once the uploads are out of
/// it: one interrupted is done again from the start.
export async function emptyWorkspace(room: string): Promise<void> {
  const workspace = join(room, "workspace");
  const archive = workspaceArchive(room);
  const rawRoom = clean(room);
  const realRoom = await realpath(room).catch(() => rawRoom);
  const worktrees = await collectWorktreeRegistrations(room);
  await mkdir(workspace, { recursive: true });
  if (await exists(archive)) {
    const stage = join(room, "workspace.emptying");
    if (await exists(stage)) await removeTree(stage);
    await mkdir(stage);
    await chmod(stage, 0o700);
    // Only its uploads' files and directories, the archive read whole all the same.
    await packedProgram().ask("workspace.unpack", { path: archive, dest: stage, prefix: "uploads" });
    await takeUploads(stage, workspace);
    await unlink(archive);
    await removeTree(stage);
  }
  // What an interrupted packing or restoring left beside it (restoreWorkspace overlays these too).
  for (const left of ["workspace.retiring", "workspace.restored-old", "workspace.restoring"]) {
    if (!(await isDir(join(room, left)))) continue;
    await takeUploads(join(room, left), workspace);
    await removeTree(join(room, left));
  }
  for (const entry of await readdir(workspace)) {
    if (entry !== "uploads") await removeTree(join(workspace, entry), { force: true });
  }
  await readingsGone(room);
  await unlockWorktrees(room);
  await removeWorktreeRegistrations(worktrees, rawRoom === realRoom ? [realRoom] : [realRoom, rawRoom]);
}

/// The files in `from`'s uploads moved into `workspace`'s, durably; those already there are kept (one put back on the
/// disk to be read, api/routes/sessions.ts, is the same file).
async function takeUploads(from: string, workspace: string): Promise<void> {
  if (!(await isDir(join(from, "uploads")))) return;
  const into = join(workspace, "uploads");
  await mkdir(into, { recursive: true });
  for (const entry of await readdir(join(from, "uploads"))) {
    if (!(await lstatOrNull(join(into, entry)))) await renameRetrying(join(from, "uploads", entry), join(into, entry));
  }
  await syncDir(into);
}

/// Whether an archived workspace holds anything `emptyWorkspace` would remove.
export async function holdsMore(room: string): Promise<boolean> {
  if (await exists(workspaceArchive(room))) return true;
  const names = await readdir(join(room, "workspace")).catch(() => [] as string[]);
  return names.some((name) => name !== "uploads");
}

/// An archived attachment is read directly from the tar stream, without inflating the whole workspace on disk.
/// `relative`: its path in the workspace.
export async function workspaceFile(room: string, relative: string): Promise<Buffer | null> {
  const archive = workspaceArchive(room);
  if (!(await exists(archive))) return null;
  // The archive's names are `/`-separated; a path from Windows has `\` too.
  const wanted = segments(relative).filter((p) => p !== "" && p !== ".");
  // Written by the shell beside the archive, read once and gone: (a name of each read's own, as the routes read one
  // while a peer's read another).
  const out = `${archive}.reading-${++reads}`;
  try {
    const { found } = await packedProgram().ask<{ found: boolean }>("workspace.file", { path: archive, wanted, out });
    return found ? await readFile(out) : null;
  } finally {
    await rm(out, { force: true });
  }
}

let reads = 0;

/// What a `workspaceFile` left beside the archive as its process ended (a crash between its write and its removal).
async function readingsGone(room: string): Promise<void> {
  for (const name of await readdir(room)) {
    if (name.startsWith("workspace.tar.zst.reading-")) await rm(join(room, name), { force: true });
  }
}
