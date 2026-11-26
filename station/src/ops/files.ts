// Files the station keeps: where its data directory is, and writing them whole (a reader never sees half a file).
import { closeSync, fsyncSync, mkdirSync, openSync, readFileSync, renameSync, writeSync } from "node:fs";
import { randomBytes } from "node:crypto";
import { copyFile, mkdir, open, opendir, rename, rm, stat, utimes } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, dirname, join } from "node:path";
import { tr, type Lang } from "./i18n.ts";
import { wall } from "./fibers.ts";
import { platform } from "../platform/index.ts";

/// The data directory: `--data`, else $STILLFAIL_DATA, else ~/.stillfail.
export function dataDir(args: string[]): string {
  const at = args.indexOf("--data");
  if (at >= 0 && args[at + 1]) return args[at + 1];
  return process.env.STILLFAIL_DATA || join(homedir(), ".stillfail");
}

/// Whether `data` is the machine's own data directory (~/.stillfail), as the launcher's
/// data.rs `is_default`: only its station takes the usual ports (4750, 4760); one on another directory (a test's, a
/// development station's) takes free ones, so it never keeps the machine's station off them.
export function ownData(data: string, home = homedir()): boolean {
  const key = (path: string) => platform.paths.key(platform.paths.clean(path));
  return key(join(home, ".stillfail")) === key(data);
}

/// Where the MCP endpoint's port is remembered (the launcher's ports.rs writes it too): agents a station leaves running
/// for the next were told it, so the next takes it again when it is free.
export const mcpPortFile = (data: string) => join(data, "run", "mcp.json");

export function rememberedMcpPort(data: string): number | undefined {
  try {
    const port = JSON.parse(readFileSync(mcpPortFile(data), "utf8")).port; // sync: read once, before the station serves
    return Number.isInteger(port) && port > 0 && port < 65536 ? port : undefined;
  } catch {
    return undefined;
  }
}

/// The ports to try, in order, for a listener of the station's own (no launcher): the one named alone; else the one
/// remembered, then the usual one on the machine's own data directory, then any (0).
export function portsToTry(named: number | undefined, remembered: number | undefined, usual: number, own: boolean): number[] {
  if (named !== undefined) return [named];
  return [...new Set([remembered, own ? usual : undefined, 0].filter((p): p is number => p !== undefined))];
}

/// Whether an argument is one of the command line's flags (`--` and a word of lowercase letters and dashes, short as
/// they all are), not a value: an enrol token (43 characters of base64url) can begin with `-` or `--`, and taken for a
/// flag it was dropped, the copied command refused with its usage (2026-11-14).
const isFlag = (a: string) => /^--[a-z][a-z-]{0,23}$/.test(a);

/// What a command is given besides its flags (each of `valued` with the value after it): in order, the command first.
/// After a bare `--`, everything is given as it is.
export function positionals(args: string[], valued: string[]): string[] {
  const out: string[] = [];
  for (let i = 0; i < args.length; i++) {
    const a = args[i]!;
    if (a === "--") { out.push(...args.slice(i + 1)); break; }
    if (!isFlag(a)) out.push(a);
    else if (valued.includes(a)) i++;
  }
  return out;
}

/// The value after `flag` in argv, wherever it is (as the Rust station reads its flags).
export function flag(args: string[], name: string): string | undefined {
  const at = args.indexOf(name);
  return at >= 0 ? args[at + 1] : undefined;
}

/// How many names beside a file this process gave (`writePrivate`, `writePrivateSoon`).
let privateWriteSeq = 0;

/// Written beside and renamed into place, synced, readable by its owner only. Beside under a name of its own (this
/// process's and a number): another process writing the same file at once (`enroll` while the station runs), or another
/// write of this one, has its own. On the caller's thread: a lock's state and key are written whole before what follows
/// them goes on (one step that must not be split).
export function writePrivate(path: string, data: string | Uint8Array) {
  mkdirSync(dirname(path), { recursive: true });
  const tmp = `${path}.${process.pid}.${++privateWriteSeq}.tmp`;
  const fd = openSync(tmp, "w", 0o600);
  try {
    writeSync(fd, typeof data === "string" ? Buffer.from(data) : data);
    fsyncSync(fd);
  } finally {
    closeSync(fd);
  }
  renameSync(tmp, path);
}

/// How long a rename waits, attempt by attempt, for a lock that clears by itself (`renameRetrying`).
export const RENAME_BACKOFF = [20, 40, 80, 160] as const;

/// What a rename that retries is given in tests: the rename itself, the wait, and the waits between attempts.
export type RenameRetry = {
  rename?: (from: string, to: string) => Promise<void>;
  wait?: (ms: number) => Promise<void>;
  backoff?: readonly number[];
};

/// Renames `from` to `to`, waiting briefly on Windows transient file or directory locks (`EPERM`, `EBUSY`, `EACCES`):
/// a virus scanner, the indexer, or a process that has just exited still holding a handle. Any other error, or one
/// still there once the backoff is spent, is thrown as it came.
export async function renameRetrying(from: string, to: string, opts?: RenameRetry): Promise<void> {
  const move = opts?.rename ?? rename;
  const wait = opts?.wait ?? wall.sleep;
  const backoff = opts?.backoff ?? RENAME_BACKOFF;
  for (let attempt = 0; ; attempt++) {
    try {
      await move(from, to);
      return;
    } catch (error) {
      const delay = backoff[attempt];
      const code = (error as NodeJS.ErrnoException)?.code;
      if (delay === undefined || (code !== "EPERM" && code !== "EBUSY" && code !== "EACCES")) throw error;
      await wait(delay);
    }
  }
}

/// `from` moved to `to`, across disks too. On one disk it is renamed. Where the two are on different disks (`EXDEV`: a
/// chat's `workspace/uploads` linked to another disk), it is copied beside `to` under a name of its own, renamed into
/// place there, and only then is `from` removed. A move cut part way leaves `from` whole, to be moved again, and never
/// half a file at `to`. The copy keeps `from`'s times, as a rename does, where the disk lets it.
export async function moveFile(from: string, to: string): Promise<void> {
  try {
    await rename(from, to);
    return;
  } catch (error) {
    if ((error as NodeJS.ErrnoException)?.code !== "EXDEV") throw error;
  }
  const was = await stat(from);
  const part = join(dirname(to), `.moving-${randomBytes(4).toString("hex")}-${basename(to)}`);
  try {
    await copyFile(from, part);
    // (a disk that will not set them, a network or FUSE mount: moved all the same)
    await utimes(part, was.atime, was.mtime).catch(() => {});
    await rename(part, to);
  } catch (error) {
    await rm(part, { force: true });
    throw error;
  }
  await rm(from, { force: true });
}

/// `writePrivate` off the station's thread: its sync waits on the disk, a fraction of a second on one kept busy. Two
/// writes of the same file at once (two sessions opening one profile) each have a name of their own beside it: through
/// one, the second's rename found none (ENOENT). What is left beside where one fails goes.
export async function writePrivateSoon(path: string, data: string | Uint8Array, opts?: RenameRetry): Promise<void> {
  await mkdir(dirname(path), { recursive: true });
  const tmp = `${path}.${process.pid}.${++privateWriteSeq}.tmp`;
  try {
    const file = await open(tmp, "w", 0o600);
    try {
      await file.writeFile(data);
      await file.sync();
    } finally {
      await file.close();
    }
    await renameRetrying(tmp, path, opts);
  } catch (error) {
    await rm(tmp, { force: true }).catch(() => {});
    throw error;
  }
}

/// A file of the station's own that it keeps in memory and writes through (`writePrivateSoon`): what is asked while a
/// write is on its way is written after it, the latest only. What it gives resolves once what was asked is written.
export class PrivateFile {
  readonly path: string;
  #latest: string | Uint8Array | null = null;
  #writing: Promise<void> | null = null;

  constructor(path: string) {
    this.path = path;
  }

  write(data: string | Uint8Array): Promise<void> {
    this.#latest = data;
    return (this.#writing ??= this.#flush());
  }

  /// Once what was asked is written (or failed).
  writing(): boolean {
    return this.#writing !== null;
  }

  async written(): Promise<void> {
    await this.#writing?.catch(() => undefined);
  }

  async #flush(): Promise<void> {
    try {
      while (this.#latest !== null) {
        const data = this.#latest;
        this.#latest = null;
        await writePrivateSoon(this.path, data);
      }
    } finally {
      this.#writing = null;
    }
  }
}

/// Seconds, as the cloud and the files say them: the machine's time.
export const nowSecs = () => Math.floor(wall.now() / 1000);

/// Whether `dir` is there but the station may not list it (EPERM, EACCES; it may still stat it), looked at off the main
/// thread. On macOS a folder the system's privacy protection keeps (Documents, Desktop, Downloads, removable and network
/// volumes) answers EPERM to a process nobody gave access to, and a station launchd runs is never asked: an agent
/// started there exits at once, saying nothing of why. Opening a folder can wait for as long as what it is on does not
/// answer (a network file system whose server is gone: OrbStack's when its machine is stopped), and the station's
/// thread with it, were it on it.
export async function unreadableDirAsync(dir: string): Promise<boolean> {
  try {
    await (await opendir(dir)).close();
    return false;
  } catch (error) {
    const code = (error as NodeJS.ErrnoException).code;
    return code === "EPERM" || code === "EACCES";
  }
}

/// What to tell when an agent's directory is unreadable (`unreadableDirAsync`): on macOS, who to give access to and where.
/// The desktop app runs its station with --with-parent and is the one macOS asks about; an installed station is its
/// stillfail-station.
export function unreadableDirMessage(lang: Lang, dir: string, argv = process.argv): string {
  if (!platform.hasFolderPermissions) return tr(lang, "station.session.cwdDenied", { cwd: dir });
  const app = flag(argv, "--app");
  const program = argv.includes("--with-parent") || !app ? "still.fail" : join(app, "mesh", "target", "release", "stillfail-station");
  return tr(lang, "station.session.cwdDeniedMac", { cwd: dir, program });
}
