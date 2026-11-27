// Cross-platform copy-on-write (reflink / clonefile) file and directory tree primitives.
// Uses native OS tools on macOS (APFS /bin/cp -c) and Node's COPYFILE_FICLONE on Linux (Btrfs/XFS/etc.)
// without requiring any prebuilt native addon rebuilds.
import { execFile } from "node:child_process";
import { randomBytes } from "node:crypto";
import { constants } from "node:fs";
import { copyFile, link, mkdir, rename, stat, unlink, utimes, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { promisify } from "node:util";
import { platform } from "../platform/index.ts";
import { wall } from "./fibers.ts";

const run = promisify(execFile);

/// Below this size on macOS, the fork/exec overhead of `/bin/cp -c` outweighs any CoW space saving.
const SMALL_CLONE_BYTES = 64 * 1024;

/// Process-wide cache of filesystem clone capability keyed by `stat(dir).dev`.
const clonesByDev = new Map<number, boolean>();

const UNSUPPORTED_ERRNO = new Set(["EOPNOTSUPP", "ENOSYS", "EXDEV", "EINVAL"]);

/// Returns whether the filesystem holding `dir` supports copy-on-write file cloning.
/// Caches per `stat.dev`; never caches `false` when `stat` or probe setup fails due to transient errors.
export async function clonesAt(dir: string): Promise<boolean> {
  if (platform.os === "windows") return false;
  const st = await stat(dir).catch(() => null);
  if (st === null) return false;
  const cached = clonesByDev.get(st.dev);
  if (cached !== undefined) return cached;

  if (platform.os === "macos") {
    const ok = await run("/bin/df", ["-T", "apfs", resolve(dir)]).then(
      () => true,
      () => false,
    );
    clonesByDev.set(st.dev, ok);
    return ok;
  }

  if (platform.os === "linux") {
    const tag = `${process.pid}-${randomBytes(6).toString("hex")}`;
    const src = join(dir, `.cow-probe-${tag}-a`);
    const dst = join(dir, `.cow-probe-${tag}-b`);
    try {
      await writeFile(src, "x");
    } catch {
      await unlink(src).catch(() => {});
      return false;
    }
    try {
      await copyFile(src, dst, constants.COPYFILE_EXCL | constants.COPYFILE_FICLONE_FORCE);
      clonesByDev.set(st.dev, true);
      return true;
    } catch (error) {
      const code = (error as NodeJS.ErrnoException).code;
      if (code !== undefined && UNSUPPORTED_ERRNO.has(code)) {
        clonesByDev.set(st.dev, false);
      }
      return false;
    } finally {
      await Promise.all([unlink(src).catch(() => {}), unlink(dst).catch(() => {})]);
    }
  }

  return false;
}

/// Returns whether `dirA` and `dirB` reside on the same clone-capable filesystem volume.
export async function sameCloneableVolume(dirA: string, dirB: string): Promise<boolean> {
  const [stA, stB] = await Promise.all([stat(dirA).catch(() => null), stat(dirB).catch(() => null)]);
  if (stA === null || stB === null || stA.dev !== stB.dev) return false;
  return await clonesAt(dirB);
}

/// Copies `from` to `to`, using copy-on-write cloning when supported on the same volume.
/// Preserves `COPYFILE_EXCL` semantics when `opts?.excl` is true and refreshes target mtime on macOS.
export async function cloneFile(from: string, to: string, opts?: { excl?: boolean }): Promise<void> {
  const flags = opts?.excl ? constants.COPYFILE_EXCL : 0;

  if (platform.os === "linux") {
    await copyFile(from, to, flags | constants.COPYFILE_FICLONE);
    return;
  }

  if (platform.os === "macos") {
    const st = await stat(from).catch(() => null);
    if (st === null || st.size < SMALL_CLONE_BYTES || !(await sameCloneableVolume(dirname(from), dirname(to)))) {
      await copyFile(from, to, flags);
      return;
    }
    const tmp = join(dirname(to), `.clone-${process.pid}-${randomBytes(6).toString("hex")}`);
    try {
      await run("/bin/cp", ["-c", "--", from, tmp]);
    } catch {
      await unlink(tmp).catch(() => {});
      await copyFile(from, to, flags);
      return;
    }
    try {
      const now = new Date(wall.now());
      await utimes(tmp, now, now);
      if (opts?.excl) {
        await link(tmp, to);
      } else {
        await rename(tmp, to);
        return;
      }
    } catch (error) {
      await unlink(tmp).catch(() => {});
      throw error;
    }
    await unlink(tmp).catch(() => {});
    return;
  }

  await copyFile(from, to, flags);
}

async function nearestExistingAncestor(dirPath: string): Promise<string | null> {
  let cur = dirPath;
  for (;;) {
    const st = await stat(cur).catch(() => null);
    if (st !== null) return cur;
    const parent = dirname(cur);
    if (parent === cur) return null;
    cur = parent;
  }
}

/// Clones the contents of `fromDir` into `toDir` using copy-on-write directory cloning.
/// Throws if `fromDir` and the nearest existing ancestor of `toDir` are not on the same clone-capable volume.
export async function cloneTree(fromDir: string, toDir: string): Promise<void> {
  const ancestor = await nearestExistingAncestor(dirname(toDir));
  if (ancestor === null || !(await sameCloneableVolume(fromDir, ancestor))) {
    throw Object.assign(new Error("Unsupported: cloneTree requires source and target on the same cloneable volume"), { code: "ENOTSUP" });
  }
  await mkdir(toDir, { recursive: true });
  if (platform.os === "macos") {
    await run("/bin/cp", ["-cRp", "--", `${fromDir}/.`, `${toDir}/`]);
    return;
  }
  if (platform.os === "linux") {
    await run("cp", ["-a", "--reflink=always", "--", `${fromDir}/.`, `${toDir}/`]);
    return;
  }
  throw Object.assign(new Error(`Unsupported: cloneTree is not supported on ${platform.os}`), { code: "ENOTSUP" });
}
