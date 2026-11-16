// A Codex copied without its code-mode host cannot use the station's tools. Recognise the native executable (including
// npm's launcher), and only offer to replace a command in the person's home. The old entry is kept as a backup.
import { randomBytes } from "node:crypto";
import { accessSync, constants, linkSync, lstatSync, readlinkSync, realpathSync, renameSync, statSync, symlinkSync, unlinkSync } from "node:fs";
import { access, lstat, open, realpath, stat } from "node:fs/promises";
import { dirname, isAbsolute, join } from "node:path";
import { platform as machine } from "../platform/index.ts";
import { withShellCommand } from "../ops/shell-path.ts";
import { type Env, type Found, findCommandSoon, run } from "./runtimes.ts";
import { platform as npmPlatform } from "./versions.ts";

const TRIPLES: Record<string, string> = {
  "linux-x64": "x86_64-unknown-linux-musl",
  "linux-arm64": "aarch64-unknown-linux-musl",
  "darwin-x64": "x86_64-apple-darwin",
  "darwin-arm64": "aarch64-apple-darwin",
};

/// A native executable, not a shell or another package manager's wrapper whose target we cannot know.
async function nativeSoon(path: string): Promise<boolean> {
  const fh = await open(path, "r").catch(() => null);
  if (fh === null) return false;
  try {
    const bytes = Buffer.alloc(4);
    if ((await fh.read(bytes, 0, bytes.length, 0)).bytesRead !== bytes.length) return false;
    return MAGIC.has(bytes.toString("hex"));
  } catch {
    return false;
  } finally {
    await fh.close().catch(() => {});
  }
}

const MAGIC = new Set(["7f454c46", "feedfacf", "cffaedfe", "feedface", "cefaedfe", "cafebabe", "bebafeca"]);

/// A file that runs.
async function executableSoon(path: string): Promise<boolean> {
  try {
    await access(path, constants.X_OK);
    return (await stat(path)).isFile();
  } catch {
    return false;
  }
}

/// Whether the code-mode host is beside `binary`.
export const hasCodexHostSoon = (binary: string): Promise<boolean> => executableSoon(join(dirname(binary), machine.exe("codex-code-mode-host")));

/// The actual executable behind npm's official launcher, or the native command itself. Unknown wrappers stay unknown.
/// Looked at off the station's thread: the software page's every reading of Codex does.
export async function codexBinarySoon(found: Found): Promise<string | null> {
  if (await nativeSoon(found.real)) return found.real;
  if (!found.real.replaceAll("\\", "/").endsWith("/node_modules/@openai/codex/bin/codex.js")) return null;
  const target = npmPlatform();
  const triple = target === null ? undefined : TRIPLES[target];
  if (!target || !triple) return null;
  const binary = await platformPackage(found.real, `@openai/codex-${target}`);
  if (binary === null) return null;
  const at = join(binary, "vendor", triple, "bin", machine.exe("codex"));
  return (await nativeSoon(at)) && (await executableSoon(at)) ? realpath(at).catch(() => null) : null;
}

/// The directory of package `name` as Node's resolution finds it from `from` (node_modules up the tree), off the
/// station's thread (createRequire's resolve looks synchronously).
async function platformPackage(from: string, name: string): Promise<string | null> {
  for (let dir = dirname(from); ; dir = dirname(dir)) {
    const at = join(dir, "node_modules", ...name.split("/"));
    if ((await stat(join(at, "package.json")).catch(() => null))?.isFile()) return realpath(at).catch(() => at);
    if (dirname(dir) === dir) return null;
  }
}

/// Only flag a missing host when this version says it uses one. Older Codex releases and unknown wrappers are left alone.
export async function missingCodexHost(
  found: Found,
  env: Env,
  features: (command: string, env: Env) => Promise<string | null> = async (command, e) => {
    try {
      const [ok, out] = await run(command, ["features", "list"], e, 20_000);
      return ok ? out : null;
    } catch {
      return null;
    }
  },
): Promise<{ binary: string; helper: string } | null> {
  const binary = await codexBinarySoon(found);
  if (binary === null) return null;
  const helper = join(dirname(binary), machine.exe("codex-code-mode-host"));
  if (await hasCodexHostSoon(binary)) return null;
  const listed = await features(found.onPath, env);
  return listed !== null && /^code_mode_host[ \t]+(?!removed\b)[^\r\n]*?[ \t]+true[ \t]*$/m.test(listed) ? { binary, helper } : null;
}

/// Resolve the command the runner will use; an unknown relative path is left for the runner to handle.
export async function findMissingCodexHost(command: string, env: Env): Promise<{ binary: string; helper: string } | null> {
  const effective = await withShellCommand(command, env);
  let found: Found | null = null;
  if (isAbsolute(command)) {
    const real = await realpath(command).catch(() => null);
    if (real !== null) found = { onPath: command, real };
  } else if (!/[\\/]/.test(command)) found = await findCommandSoon(command, effective);
  return found ? missingCodexHost(found, effective) : null;
}

/// Changing a command in a system directory or through a directory link out of the home is not an automatic repair.
export function canSwitchCodex(found: Found, env: Env): boolean {
  if (!machine.codexStandalone || !isAbsolute(found.onPath)) return false;
  const home = machine.home(env);
  if (!home) return false;
  try {
    const dir = realpathSync(dirname(found.onPath));
    if (!machine.paths.within(dir, realpathSync(home))) return false;
    accessSync(dir, constants.W_OK);
    const entry = lstatSync(found.onPath);
    return (entry.isFile() || entry.isSymbolicLink()) && realpathSync(found.onPath) === found.real;
  } catch {
    return false;
  }
}

/// `canSwitchCodex` off the station's thread (the software page's reading of Codex, and a repair's first look).
export async function canSwitchCodexSoon(found: Found, env: Env): Promise<boolean> {
  if (!machine.codexStandalone || !isAbsolute(found.onPath)) return false;
  const home = machine.home(env);
  if (!home) return false;
  try {
    const dir = await realpath(dirname(found.onPath));
    if (!machine.paths.within(dir, await realpath(home))) return false;
    await access(dir, constants.W_OK);
    const entry = await lstat(found.onPath);
    return (entry.isFile() || entry.isSymbolicLink()) && (await realpath(found.onPath)) === found.real;
  } catch {
    return false;
  }
}

type Identity = { dev: number; ino: number; size: number; mtimeMs: number };
export type CodexEntry = { found: Found; entry: Identity; target: Identity };
const identity = (s: Identity): Identity => ({ dev: s.dev, ino: s.ino, size: s.size, mtimeMs: s.mtimeMs });
const same = (a: Identity, b: Identity) => a.dev === b.dev && a.ino === b.ino && a.size === b.size && a.mtimeMs === b.mtimeMs;

/// Remember the entry and its target before npm runs, so a change made meanwhile is never replaced.
export async function captureCodexSoon(found: Found, env: Env): Promise<CodexEntry | null> {
  if (!(await canSwitchCodexSoon(found, env))) return null;
  try {
    return { found, entry: identity(await lstat(found.onPath)), target: identity(await stat(found.onPath)) };
  } catch {
    return null;
  }
}

/// Installs the new link only if the entry still names the one checked; the old entry, including a symlink, is kept.
export function switchCodex(captured: CodexEntry, launcher: string, env: Env): string {
  const { found } = captured;
  if (!canSwitchCodex(found, env)) throw new Error("Codex command changed or is not writable in the home directory");
  const suffix = randomBytes(8).toString("hex");
  const backup = `${found.onPath}.stillfail-backup-${suffix}`;
  if (!same(identity(lstatSync(found.onPath)), captured.entry) || !same(identity(statSync(found.onPath)), captured.target) || realpathSync(found.onPath) !== found.real) throw new Error("Codex command changed while repairing it");
  renameSync(found.onPath, backup);
  try {
    const saved = lstatSync(backup);
    if (!same(identity(saved), captured.entry) || !same(identity(statSync(backup)), captured.target) || (saved.isSymbolicLink() && realpathSync(backup) !== found.real)) throw new Error("Codex command changed while repairing it");
    // symlink() fails if someone created an entry while the old one was being moved; it never replaces theirs.
    symlinkSync(launcher, found.onPath);
    return backup;
  } catch (error) {
    try {
      restoreEntry(backup, found.onPath);
    } catch {
      throw new Error(`Codex command could not be restored; its backup is ${backup}`);
    }
    throw error;
  }
}

/// Link the saved entry back without replacing any command someone created in the meantime.
function restoreEntry(backup: string, path: string): void {
  if (lstatSync(backup).isSymbolicLink()) symlinkSync(readlinkSync(backup), path);
  else linkSync(backup, path);
  unlinkSync(backup);
}

/// Do not overwrite a command someone changed after the switch, even when a later validation fails.
export function restoreCodex(path: string, launcher: string, backup: string): void {
  const entry = lstatSync(path);
  if (!entry.isSymbolicLink() || readlinkSync(path) !== launcher) throw new Error(`Codex command changed; its backup is ${backup}`);
  const moved = `${path}.stillfail-failed-${randomBytes(8).toString("hex")}`;
  renameSync(path, moved);
  try {
    if (!same(identity(lstatSync(moved)), identity(entry)) || readlinkSync(moved) !== launcher) throw new Error("Codex command changed while restoring it");
    restoreEntry(backup, path);
  } catch (error) {
    try { restoreEntry(moved, path); } catch {}
    throw new Error(`Codex command could not be restored; its backup is ${backup}: ${(error as Error).message}`);
  }
  try { unlinkSync(moved); } catch {}
}
