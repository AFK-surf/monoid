// What src/ops/places.ts `realOutside` and drive/fs.ts `protectedPlace` did on the thread that asked, before the station
// looked off its main thread (lstat, readlink and realpath of node:fs/promises; a place in /Volumes as last looked at):
// the reference readers (sessions.ts `sessionPlace`) are held to it, as the MoonBit program that replaced them is.
import { lstatSync, readlinkSync, realpathSync } from "node:fs";
import { homedir } from "node:os";
import { resolve } from "node:path";
import { protectedPlace as byNameKept } from "../../src/drive/fs.ts";
import { platform } from "../../src/platform/index.ts";

type Where = { top: string; helper: boolean };

/// The folder macOS protects `path` is in, a place in /Volumes looked at now (a link to / there is the system's own).
export function protectedPlace(path: string, home = homedir(), mounts = platform.mounts()): Where | null {
  const disk = /^\/volumes\/([^/]+)/i.exec(path);
  const named = byNameKept(path, home, mounts);
  if (named === null || disk === null || named.top !== `/Volumes/${path.split("/")[2]}`) return named;
  try {
    return lstatSync(named.top).isSymbolicLink() ? null : named;
  } catch {
    return null;
  }
}

const parts = (path: string) => path.split("/").filter((p) => p !== "" && p !== ".");
const joined = (p: string[]) => `/${p.join("/")}`;

/// `path` with its links followed, as realpath has it: on macOS without stepping into a folder macOS protects (one in
/// such a folder is said as far as it was followed, by its name); null when it is not there.
export function realOutside(path: string, home = homedir()): string | null {
  if (!platform.hasFolderPermissions) {
    try {
      return realpathSync(path);
    } catch {
      return null;
    }
  }
  let pending = parts(resolve(path));
  let done: string[] = [];
  let hops = 0;
  while (pending.length > 0) {
    const name = pending.shift()!;
    if (name === "..") {
      done.pop();
      continue;
    }
    const next = [...done, name];
    const at = joined(next);
    if (protectedPlace(at, home) !== null) return joined([...next, ...pending]);
    let link: boolean;
    try {
      link = lstatSync(at).isSymbolicLink();
    } catch {
      return null;
    }
    if (!link) {
      done = next;
      continue;
    }
    if (++hops > 40) return null;
    const target = readlinkSync(at);
    if (target.startsWith("/")) done = [];
    pending = [...parts(target), ...pending];
  }
  try {
    return realpathSync(joined(done));
  } catch {
    return null;
  }
}
