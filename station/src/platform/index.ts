// What differs between the machines a station runs on (macOS, Linux, Windows), in this directory and nowhere else:
// the rest of src/ is one logic for all of them, and asks `platform` for what a machine does its own way
// (test/platform.test.ts keeps it so: no process.platform, `win32` or WINDOWS outside src/platform/).
//
// What is asked is what the station means to do (end a job's group, make a command another program can run, join a
// path as Rust does), not which machine this is; a feature only one machine has is a flag saying so (hasKeychain).
import type { ChildProcess } from "node:child_process";
import { isBackgroundWrapperExecFailure, isBackgroundWrapperStderrLine, unix } from "./unix.ts";
import { windows } from "./windows.ts";

export { isBackgroundWrapperExecFailure, isBackgroundWrapperStderrLine };

export type Env = Record<string, string | undefined>;
/// A command found on PATH: as found there, and the file it is once links are followed.
export type Found = { onPath: string; real: string };
/// A program and its arguments, as runtimes are installed and updated.
export type How = { program: string; args: string[] };

/// A process as the memory watch sees it (jobs/memory.ts).
export type ProcessInfo = { pid: number; ppid: number; pgid: number; bytes: number; command: string };

/// A process table as a tree: each process by its pid, and the pids of each one's children.
export function treeOf(table: readonly ProcessInfo[]): { byPid: Map<number, ProcessInfo>; children: Map<number, number[]> } {
  const children = new Map<number, number[]>();
  const byPid = new Map<number, ProcessInfo>();
  for (const p of table) {
    byPid.set(p.pid, p);
    if (p.pid !== p.ppid) children.set(p.ppid, [...(children.get(p.ppid) ?? []), p.pid]);
  }
  return { byPid, children };
}

/// What the host page says of the machine besides its CPUs' time (api/host.ts `hostInfo`).
export type HostSample = {
  memory: { totalBytes: number; usedBytes: number; swapUsedBytes: number | null; known?: boolean };
  cpuModel: string;
  uptimeSec: number;
  osName: string;
  /// This process's memory: its footprint on macOS, resident memory elsewhere.
  ownRss: number;
};

/// How the host page says the machine (GET /host): memory, CPU, uptime, the OS.
export type Host = {
  /// CPU time since boot, all CPUs together: (busy, total); none when it cannot be read. At once where the system's
  /// counters give it (os.cpus: macOS, Windows), else a file read off the station's thread (Linux's /proc/stat).
  cpuTicks(): [busy: number, total: number] | null | Promise<[busy: number, total: number] | null>;
  /// The rest, read with commands and files not waited on: it is read on the main thread (api/host.ts).
  sample(): Promise<HostSample>;
};

/// A Node release's build for one machine, as nodejs.org has it: `dist` (node-v<version>-<os>-<arch>), its `archive` in
/// the release's directory (`dist` at its top), where in it its commands are (`bin`, relative: node, npm, and what that
/// npm installs with `--prefix` the build), npm's name there, and the tar that unpacks the archive.
export type NodeBuild = { dist: string; archive: string; bin: string; npm: string; tar: string };

export type Platform = {
  /// std::env::consts::OS as Rust names it (macos, linux, windows; another its own name): what a station says it runs
  /// on to its peers and in feedback.
  os: string;
  /// How the runtimes name a build's OS (darwin, linux, win32); none for another.
  buildOs: string | null;
  /// Whether a file copied on a disk of this machine can be a clone of it, taking no room of its own (APFS: macOS).
  clonesFiles: boolean;
  /// The machine's cache of native parts, which scripts/native.ts keeps and every worktree and station process shares:
  /// $STILLFAIL_NATIVE_CACHE, else ~/Library/Caches/stillfail-native (macOS), $XDG_CACHE_HOME/stillfail-native or
  /// ~/.cache/stillfail-native (Linux), %LOCALAPPDATA%\stillfail-native (Windows).
  nativeCache: (env: Env, home: string) => string;

  // Commands and their environment.
  /// An executable's file name (`stillfail-runner` → `stillfail-runner.exe` on Windows).
  exe(name: string): string;
  /// The user's home as `env` says it.
  home(env: Env): string | undefined;
  /// PATH as `env` has it (on Windows `Path` as often as not).
  pathOf(env: Env): string;
  /// `env` with `dir` first on its PATH (one PATH variable, whatever its case).
  prependPath(env: NodeJS.ProcessEnv, dir: string): NodeJS.ProcessEnv;
  /// `dir` put last on `env`'s own PATH, in place, unless it is on it already (one PATH variable, whatever its case).
  appendPath(env: Env, dir: string): void;
  /// A command on `env`'s PATH as a shell finds it (with PATHEXT's extensions on Windows).
  findCommand(name: string, env: Env): Found | null;
  /// `findCommand` off the station's thread: each place on PATH looked at in turn, the first found.
  findCommandSoon(name: string, env: Env): Promise<Found | null>;
  /// The user's interactive shell, when this machine has one to read a PATH from.
  userShell(env: Env): string | null;
  /// The PATH a process started now would be given, where the machine keeps it apart from a shell (Windows' registry:
  /// the machine's, then the user's, each `%VAR%` expanded): what an installer put there after this process started,
  /// which a running process is never given. None on Unix, where the shell's startup files say it (`userShell`).
  savedPath(env: Env): Promise<string[] | null>;
  /// How Node runs a command (a name on PATH, or a path) with `args`: on Windows a .cmd is run around cmd when it can
  /// be (npm's, Vite+'s), else through it, quoted.
  runnable(command: string, args: string[], env: NodeJS.ProcessEnv): { file: string; args: string[]; windowsVerbatimArguments?: true };
  /// `runnable` off the station's thread (on Windows, PATH looked in and a shim read).
  runnableSoon(command: string, args: string[], env: NodeJS.ProcessEnv): Promise<{ file: string; args: string[]; windowsVerbatimArguments?: true }>;
  /// The shell jobs, device commands and the vault's runs go under (/bin/sh; Git for Windows' sh, found by `env`: an
  /// error that says how to get it where there is none). On Windows it looks on disk on the station's thread: only for
  /// what runs before the station serves (`makeCommand`); what runs after asks `posixShellSoon`
  /// (test/src-sync-calls.test.ts holds it).
  posixShell(env?: NodeJS.ProcessEnv): string;
  /// `posixShell` off the station's thread; on Windows, where `env` finds none, by the PATH the registry gives a
  /// process started now too (`savedPath`: Git installed since the station started).
  posixShellSoon(env?: NodeJS.ProcessEnv): Promise<string>;
  /// A command as a group of its own, ended whole (as spawned detached on Unix; under `stillfail-runner --job` on
  /// Windows).
  grouped(program: string, args: string[]): [string, string[]];
  /// A command started `by` lower in CPU priority than this process (ops/nice.ts): under nice where there is one; as
  /// it is on Windows (no nice).
  lowered(program: string, args: string[], by: number): [string, string[]];
  /// A command started as the system's background work (the station's own builders and indexers, read/mb-reader.ts):
  /// its CPU and its disk's reads and writes both yield to the foreground's. macOS: under `/usr/sbin/taskpolicy -b`
  /// (PRIO_DARWIN_BG: background CPU QoS and IOPOL_THROTTLE, for it and all it starts), where nice alone leaves APFS's
  /// IO as it was; Linux: under `ionice -t -c2 -n7` and `nice -n 10` (best-effort's lowest IO, a lower CPU priority);
  /// else as `lowered` by 10; as it is on Windows. Each wrapper execs the command, which keeps its pid.
  backgrounded(program: string, args: string[]): [string, string[]];
  /// The command that writes out what the file system holding `dir` has of written files (replica/sending.ts
  /// `flushOnce`): Linux's `sync -f <dir>`, that file system only; macOS's `sync`, every one; none on Windows.
  flushing(dir: string): [string, string[]] | null;
  /// A shell script at `path` runnable by name from any shell: on Windows a `.cmd` beside it too, running it with the
  /// POSIX shell, or doing nothing when `noop`. The name a program is to be given for it (the .cmd on Windows).
  makeCommand(path: string, script: string, noop?: boolean): string;
  /// `makeCommand` off the station's thread, each file written beside and renamed into place: a command that runs it
  /// meanwhile finds the one before or this one whole, never half of it. One already as it is to be is left alone.
  makeCommandSoon(path: string, script: string, noop?: boolean): Promise<string>;

  // Process groups (ops/group.ts).
  /// Signals a whole group; one already gone is no error. On Windows any signal ends it.
  signalGroup(pgid: number, signal: NodeJS.Signals): void;
  /// Signals a child that leads a group (spawned detached, or `grouped`), and what it started.
  signalChildGroup(child: ChildProcess, signal: NodeJS.Signals): void;
  /// Whether any process of the group is there.
  groupAlive(pgid: number): boolean;
  /// When `pid` started (ms), none when it is not running or cannot be read.
  startTimeOf(pid: number): Promise<number | null>;
  /// Whether a group lives on without its leader (a Unix group while any member does; a Windows job dies with it).
  groupOutlivesLeader: boolean;
  /// Memory of each group (kB).
  groupMemory(pgids: number[]): Promise<Map<number, number>>;
  /// The processes holding a TCP socket whose own (local) port is `port` on this machine: who is at the other end of a
  /// loopback connection a listener took from that port (adb/servers.ts: only a grant's adb server is let in). Empty
  /// when it cannot be told.
  tcpPortPids(port: number): Promise<number[]>;

  // Paths.
  paths: {
    /// What separates a path's components.
    separator: RegExp | string;
    /// The separator a path is joined with.
    sep: string;
    /// A path absolute, `.` and `..` worked out lexically (no link followed).
    clean(path: string): string;
    /// What two paths are compared by (on Windows case does not tell them apart).
    key(path: string): string;
    /// Path::starts_with on keyed paths: `path` is `dir` or under it.
    within(path: string, dir: string): boolean;
    /// Whether a path's only component is a root and not a name (a drive, `C:`).
    isRootName(part: string): boolean;
    /// Whether a path given as relative starts somewhere of its own: `/`; on Windows also a drive, a share or a
    /// stream (`a:b`).
    rooted(path: string): boolean;
    /// Path::join as Rust has it: an absolute `given` replaces `base`; nothing is normalised.
    join(base: string, given: string): string;
    /// `path` relative to `root` when it is `root` or under it (whole components), else none.
    relativeIn(root: string, path: string): string | null;
    /// Whether a link's text is a local path by its form alone (on Windows a drive's path, `C:\…`).
    isDrivePath(text: string): boolean;
  };

  // Files.
  /// The disks mounted, as places to start a folder from (the drive's picker): macOS's in /Volumes, Linux's in
  /// /media/<user> and /mnt (each folder there, names in order); Windows' drives, `C:\` to `Z:\`, by their letter.
  /// Each as it is there, not yet looked into: a link to `/` (macOS's own disk) is the caller's to leave out.
  disks(home: string): Promise<{ name: string; path: string }[]>;
  /// Where file systems other than the machine's own volumes are mounted (a network share, OrbStack's NFS in the home,
  /// a disk), wherever that is: macOS asks the person before a process opens one, so the station never does itself
  /// (drive/fs.ts protectedPlace). macOS's, as `mount` says them (read again in the background when asked a while
  /// after the last read, never on the thread: none until the first read, which asking starts, is in); none elsewhere.
  mounts(): string[];
  /// `mounts`, read first (off the thread) where it was not yet or is stale.
  mountsSoon(): Promise<string[]>;
  /// Whether making a symbolic link was refused for want of the privilege (Windows without Developer Mode).
  linkRefused(error: unknown): boolean;
  /// Whether a directory's entries can be made durable by syncing it (not on Windows: NTFS journals them).
  syncsDirectories: boolean;
  /// `link` the same file as `target`, kept so: a symbolic link, or where one is refused a hard link.
  shareFile(target: string, link: string): Promise<void>;

  // The runner (agents/runner.ts).
  /// Whether a runner's socket is a file that can be looked at without connecting (not a Windows pipe).
  runnerSocketVisible: boolean;
  /// Whether the station says `leave` before letting go of a runner (a pipe has no closing of one side).
  runnerSaysLeave: boolean;

  // The machine (api/host.ts).
  host: Host;

  // The launcher (native/launcher), as the CLI and the station's own update reach it.
  /// Whether process `pid` is a station's launcher (pids get reused).
  isLauncher(pid: number): Promise<boolean>;
  /// Asks the launcher `pid` to hand over to a new process, to drain, or to read the channel again: Unix's SIGUSR2,
  /// SIGUSR1, SIGHUP; on Windows, which has no signals, a line on its own pipe. Throws when it is not reached.
  askLauncher(pid: number, op: "handover" | "drain" | "hup"): Promise<void>;

  // Updates.
  /// How Claude Code is installed where it is not.
  claudeInstall: How;
  /// How the Devin CLI is installed where it is not (its own installer, into ~/.local/bin).
  devinInstall: How;
  /// How the Antigravity CLI is installed where it is not (its own installer: its binary into ~/.local/bin on macOS and
  /// Linux, %LOCALAPPDATA%\\agy\\bin on Windows; it writes no shell profile).
  agyInstall: How;
  /// Which of the Antigravity CLI's builds that installer downloads here, as its manifests name it (darwin_arm64,
  /// linux_amd64, windows_amd64…); null for one not measured here (a musl Linux's, Termux's, another architecture's).
  agyBuild: () => Promise<string | null>;
  /// Where that installer downloads build `url` before it checks it: ~/.cache/antigravity/staging (agy.tar.gz, or agy
  /// where it is not a tarball), %LOCALAPPDATA%\antigravity\staging\agy.exe on Windows.
  agyStaging: (env: Env, url: string) => string | null;
  /// The kind of the installer a release carries for this machine: bin/install.<lang>.<this> (scripts/installers.ts).
  installerExt: "sh" | "ps1";
  /// Starts `script` (the installer the running release carries, scripts/release-sign.ts) apart from the station, run
  /// from a copy in `runDir`, its exit to run/update.exit and what it said to run/update.log. Whether it was started.
  startInstaller(script: string, runDir: string, env: Record<string, string>, app: string): Promise<boolean>;
  /// How a runtime found as a package manager's of this machine's kind is updated (Windows: winget's package, Vite+'s
  /// shim beside vp.exe, npm's .cmd in its prefix), none for the shared rules.
  shimUpdate(found: Found, pkg: string, env: Env): Promise<How | "no-npm" | null>;
  /// How a runtime `shimUpdate` would update is removed the same way (Windows: `winget uninstall` of its package,
  /// `vp.exe uninstall -g`, npm's `uninstall -g` in that prefix), none for the shared rules.
  shimUninstall(found: Found, pkg: string, env: Env): Promise<How | "no-npm" | null>;
  /// `command` (a command npm installed in its global prefix) linked into `dir` under its name, where nothing of that
  /// name is: whether it now is (not on Windows: npm's .cmd finds its package beside itself, and its prefix is on PATH).
  linkCommand(command: string, dir: string): Promise<boolean>;
  /// Whether Codex's standalone install updates by its installer here, and installs by it (a shell script: not on
  /// Windows).
  codexStandalone: boolean;
  /// Node's build for this machine as nodejs.org names it, for npm where the machine has none (updates/runtimes.ts
  /// OwnNode); none where nodejs.org has no build for it.
  nodeBuild(version: string): NodeBuild | null;

  // Sleep (ops/awake.ts).
  /// Keeps the machine from going to sleep for want of use, `why` said where the system shows it: a process of its own
  /// holds the system's say-so (Windows' SetThreadExecutionState, macOS's caffeinate, systemd-inhibit) until the
  /// returned function lets go, or the station is gone; none where there is no way to.
  holdAwake(why: string): (() => void) | null;

  // The station's browser (src/browser/).
  /// Where a Chrome may be on this machine, best first: Google Chrome's, then Chromium's and Edge's (each a file that
  /// is there).
  browsers(env: Env): string[];
  /// `browsers` off the station's thread.
  browsersSoon(env: Env): Promise<string[]>;
  /// Whether a program here can show windows (a browser with its own): a Mac's or Windows' desktop; on Linux a display
  /// the environment names (DISPLAY, WAYLAND_DISPLAY).
  hasDisplay(env: Env): boolean;
  // Logins to command-line tools (logins/run.ts, logins/relay.ts).
  /// `program` with `args` in a pseudo-terminal of `cols` × `rows` (stdin a pipe, kept open: closing it ends the
  /// command), as the system's `script` gives one: the program and arguments to start; none where there is no such way
  /// (Windows: the command runs on pipes). Where `script` is is looked for off the station's thread.
  terminalSoon(program: string, args: string[], cols: number, rows: number): Promise<[string, string[]] | null>;
  /// The processes `pid` started, and theirs (not itself).
  descendants(pid: number): Promise<number[]>;
  // Memory, as the station's queue and its watch over the agents' processes read it (jobs/admit.ts, jobs/memory.ts).
  /// What the system says of its memory: macOS's own pressure level; elsewhere how much is still available
  /// (pressureOfAvailable). None when it cannot be read.
  memoryPressure(): Promise<"normal" | "high" | "critical" | null>;
  /// How long the machine's input (keyboard, pointer, what a screen's viewer sends) has been idle, in ms: a person at it
  /// or working it through still.fail (the station's queue gives the screen to no task meanwhile, jobs/admit.ts). None
  /// where it is not read.
  inputIdleMs(): Promise<number | null>;
  /// Every process: its parent, group, program and memory in bytes (resident; its footprint on macOS when `exact`,
  /// which takes longer to read but counts what is compressed or swapped out). None where it is not read (Windows).
  processTable(exact: boolean): Promise<ProcessInfo[] | null>;
  /// The working directory of each of `pids` that says one.
  cwds(pids: number[]): Promise<Map<number, string>>;
  /// The addresses those processes listen on at TCP `port` (127.0.0.1, ::1, * for all); null when this machine cannot
  /// tell.
  listening(pids: number[], port: number): Promise<string[] | null>;
  /// The programs `pids` run (their names, as `ps` gives them); none where not told.
  commands(pids: number[]): Promise<string[]>;
  /// Whether the terminal process `pid` runs in echoes what is typed: false only while a line is read without echo (a
  /// password), not while keys are read one by one (a menu); null when not told.
  echoes(pid: number): Promise<boolean | null>;

  // What only some machines have.
  /// The macOS keychain (Claude Code keeps its login there).
  hasKeychain: boolean;
  /// The trash its file browser deletes to (drive/trash.ts): Finder's (`finder`: ~/.Trash, a disk's .Trashes/<uid>),
  /// the freedesktop one (`freedesktop`: files/ and info/), or none the drive puts into (Windows).
  trash: "finder" | "freedesktop" | null;
  /// QuickLook's thumbnails (qlmanage).
  hasQuickLook: boolean;
  /// Privacy permissions a folder can be denied by (macOS's).
  hasFolderPermissions: boolean;
  /// Spotlight's index of the machine's files, asked with `mdfind` (macOS's): the search finds files through it.
  hasSpotlight: boolean;
  /// What shows the machine's display to a client and drives it: still.fail Helper (macOS),
  /// stillfail-screen (Windows), X11 (Linux), or nothing.
  desktopScreen: "helper" | "screen" | "x11" | null;
  /// Unix domain sockets at a path: how the station and its modules talk.
  hasUnixSockets: boolean;
};

export const platform: Platform = process.platform === "win32" ? windows : unix;
/// For tests and the few places that must say which: whether this is Windows.
export const WINDOWS = process.platform === "win32";
