// macOS and Linux (and another Unix as Linux): process groups and signals, /bin/sh, `/` paths, links. What the two
// differ in (how the machine reads: sysctl and vm_stat, or /proc; the keychain and QuickLook) is said here too.
import { type ChildProcess, execFile, spawn } from "node:child_process";
import { chmodSync, existsSync, readdirSync, readlinkSync, realpathSync, statSync, writeFileSync } from "node:fs";
import { release, type as osType, userInfo } from "node:os";
import { basename, delimiter, join } from "node:path";
import { access, chmod, copyFile, lstat, readFile, readdir, readlink, realpath, rename, rm, stat, symlink, unlink, writeFile } from "node:fs/promises";
import { randomUUID } from "node:crypto";
import { promisify } from "node:util";
import { wall } from "../ops/fibers.ts";
import type { Env, Found, Host, HostSample, Platform } from "./index.ts";
import { holder, osCpuTicks } from "./processes.ts";
import { elasticMemory, fieldOrNull, firstWord, idleOfIoreg, isDom0MemAnswer, isMonoidStationVm, parseF64, parseLsof, parseMounts, parsePs, parseTopMem, parseU64, pressureOfAvailable, pressureOfLevel, pressureOfMemoryPsi, pressureOfSwap, procStatTicks, swapoutsOf, swapUsedOf, trim, worsePressure } from "./text.ts";

const MACOS = process.platform === "darwin";
/// Names in the order people read them (numbers by value, case aside), as the drive sorts them.
const collator = new Intl.Collator(undefined, { numeric: true, sensitivity: "base" });

const run = promisify(execFile);

const executable = (p: string) => {
  try {
    const st = statSync(p);
    return st.isFile() && (st.mode & 0o111) !== 0;
  } catch {
    return false;
  }
};
const executableSoon = async (p: string) => {
  const st = await stat(p).catch(() => null);
  return st !== null && st.isFile() && (st.mode & 0o111) !== 0;
};
/// Where a Chrome may be (Platform.browsers), best first: macOS's apps, the machine's then the user's; elsewhere the
/// commands on PATH (`onPath`: where one is found, none where it is not) and Google's own place.
function browserPlaces<T>(env: Env, onPath: (name: string) => T): (string | T)[] {
  const home = env.HOME ?? "";
  const apps = (name: string, binary: string) => [`/Applications/${name}.app/Contents/MacOS/${binary}`, join(home, "Applications", `${name}.app`, "Contents", "MacOS", binary)];
  return MACOS
    ? [...apps("Google Chrome", "Google Chrome"), ...apps("Chromium", "Chromium"), ...apps("Microsoft Edge", "Microsoft Edge")]
    : [
        ...["google-chrome-stable", "google-chrome"].map(onPath),
        "/opt/google/chrome/chrome",
        ...["chromium", "chromium-browser", "microsoft-edge-stable", "microsoft-edge"].map(onPath),
      ];
}
const real = (p: string) => {
  try {
    return realpathSync(p);
  } catch {
    return null;
  }
};

/// How this machine starts a command as background work (Platform.backgrounded): which wrapper is here, looked for
/// once. macOS's taskpolicy; Linux's ionice (util-linux's: busybox's has no `-t`, without which a container that refuses
/// the IO class would refuse to run the command) and nice; nice alone; nothing.
export type Background = { kind: "taskpolicy" } | { kind: "ionice"; ionice: string; nice: string } | { kind: "nice"; nice: string } | { kind: "none" };

let backgroundFound: Background | null = null;
function background(): Background {
  if (backgroundFound !== null) return backgroundFound;
  const there = (p: string) => existsSync(p); // sync: a stat or two, once for the process
  const nice = ["/usr/bin/nice", "/bin/nice"].find(there);
  if (MACOS && there("/usr/sbin/taskpolicy")) backgroundFound = { kind: "taskpolicy" };
  else {
    const ionice = MACOS ? undefined : ["/usr/bin/ionice", "/bin/ionice"].find((p) => there(p) && !/busybox/.test(real(p) ?? p));
    backgroundFound = ionice !== undefined && nice !== undefined ? { kind: "ionice", ionice, nice } : nice !== undefined ? { kind: "nice", nice } : { kind: "none" };
  }
  return backgroundFound;
}

/// Whether /usr/bin/nice is here (Platform.lowered), looked for once.
let niceFound: boolean | null = null;
const niceThere = (): boolean => (niceFound ??= existsSync("/usr/bin/nice")); // sync: a stat, once for the process

/// `program` with `args` under the wrapper `how`.
export function backgroundedOn(how: Background, program: string, args: string[]): [string, string[]] {
  switch (how.kind) {
    case "taskpolicy": return ["/usr/sbin/taskpolicy", ["-b", program, ...args]];
    case "ionice": return [how.ionice, ["-t", "-c2", "-n7", how.nice, "-n", "10", program, ...args]];
    case "nice": return [how.nice, ["-n", "10", program, ...args]];
    case "none": return [program, args];
  }
}

/// Whether a stderr line looks like a diagnostic from a background wrapper (`taskpolicy`, `nice`, `ionice`).
export function isBackgroundWrapperStderrLine(command: string, line: string): boolean {
  if (/(?:^|\/)taskpolicy$/.test(command)) return /^taskpolicy:\s+posix_spawn:/.test(line);
  if (/(?:^|\/)nice$/.test(command)) return /^(?:.*\/)?nice:\s/.test(line);
  if (/(?:^|\/)ionice$/.test(command)) return /^(?:.*\/)?(?:ionice|nice):\s/.test(line);
  return false;
}

/// Whether a backgrounded wrapper (`taskpolicy`, `nice`, `ionice`) failed to exec the target binary
/// (missing file, bad shebang, permission denied), rather than the target running and returning an exit code.
export function isBackgroundWrapperExecFailure(
  command: string,
  code: number | null,
  signal: NodeJS.Signals | null,
  stderrLines: readonly string[],
): boolean {
  if (signal !== null || code === null || code === 0) return false;
  if (/(?:^|\/)taskpolicy$/.test(command)) {
    return stderrLines.some((l) => isBackgroundWrapperStderrLine(command, l));
  }
  if (/(?:^|\/)nice$/.test(command)) {
    return (code === 126 || code === 127) && stderrLines.some((l) => isBackgroundWrapperStderrLine(command, l));
  }
  if (/(?:^|\/)ionice$/.test(command)) {
    return (code === 126 || code === 127 || code === 1) && stderrLines.some((l) => isBackgroundWrapperStderrLine(command, l));
  }
  return false;
}

/// files.rs `clean` on Unix: the path absolute (a leading `/`), `.` and `..` worked out lexically.
function clean(path: string): string {
  const out: string[] = [];
  for (const part of path.split("/")) {
    if (part === "" || part === ".") continue;
    if (part === "..") out.pop();
    else out.push(part);
  }
  return `/${out.join("/")}`;
}

/// When `pid` started (ms): from its elapsed time as ps says it ([[dd-]hh:]mm:ss). Not waited on: under memory pressure
/// a process takes seconds to start, and every device and agent waited on each one the main thread started.
async function startTimeOf(pid: number): Promise<number | null> {
  let text: string;
  try {
    text = (await run("ps", ["-o", "etime=", "-p", String(pid)], { encoding: "utf8" })).stdout.trim();
  } catch {
    return null;
  }
  if (text === "") return null;
  let days = 0;
  let rest = text;
  const dash = text.indexOf("-");
  if (dash >= 0) {
    days = Number(text.slice(0, dash));
    rest = text.slice(dash + 1);
    if (!Number.isInteger(days)) return null;
  }
  const parts = rest.split(":").map(Number);
  if (parts.some((p) => !Number.isInteger(p))) return null;
  let seconds: number;
  if (parts.length === 3) seconds = parts[0]! * 3600 + parts[1]! * 60 + parts[2]!;
  else if (parts.length === 2) seconds = parts[0]! * 60 + parts[1]!;
  else return null;
  // ps says it on the machine's time.
  return wall.now() - (seconds + days * 86_400) * 1000;
}

/// macOS's memory (host.memory) from what sysctl and vm_stat said; `swap` asked only when the rest is known.
function macMemoryOf(totalText: string | null, vm: string | null, swap: () => string | null): HostSample["memory"] {
  const total = parseU64(totalText ?? "") ?? 0;
  if (vm !== null) {
    const after = vm.split("page size of ")[1];
    const page = after !== undefined ? parseU64(firstWord(after)) : null;
    const anonymous = fieldOrNull(vm, "Anonymous pages");
    const purgeable = fieldOrNull(vm, "Pages purgeable");
    const wired = fieldOrNull(vm, "Pages wired down");
    const compressed = fieldOrNull(vm, "Pages occupied by compressor");
    if (total > 0 && page !== null && page > 0 && anonymous !== null && purgeable !== null && wired !== null && compressed !== null) {
      const used = Math.max(anonymous - purgeable + wired + compressed, 0) * page;
      const usedText = swap()?.split("used = ")[1]?.split("M")[0];
      const swapMb = usedText === undefined ? null : parseF64(usedText);
      return { totalBytes: total, usedBytes: Math.min(used, total), swapUsedBytes: swapMb === null ? null : Math.round(swapMb * 1024 * 1024) };
    }
  }
  return { totalBytes: total, usedBytes: 0, swapUsedBytes: null, known: false };
}

/// What memoryPressure reads on macOS, its commands not waited on (the main thread's): the memory (host.memory) and
/// what the swap says of it, pages swapped out a second since the last look (`lastSwapouts`).
let lastSwapouts: { pages: number; at: number } | null = null;
async function macPressureReading(): Promise<{ memory: HostSample["memory"]; swap: "normal" | "high" | "critical" | null }> {
  const said = async (command: string, args: string[]) => {
    try {
      return trim((await run(command, args, { encoding: "utf8", timeout: 3000 })).stdout);
    } catch {
      return null;
    }
  };
  const [total, vm, swap] = await Promise.all([said("sysctl", ["-n", "hw.memsize"]), said("vm_stat", []), said("sysctl", ["-n", "vm.swapusage"])]);
  const memory = macMemoryOf(total, vm, () => swap);
  const pages = swapoutsOf(vm);
  const now = wall.now();
  const before = lastSwapouts;
  lastSwapouts = pages === null ? null : { pages, at: now };
  const perSecond = pages === null || before === null || now <= before.at || pages < before.pages ? null : ((pages - before.pages) * 1000) / (now - before.at);
  return { memory, swap: pressureOfSwap(swapUsedOf(swap), memory.totalBytes > 0 ? memory.totalBytes : null, perSecond) };
}

const DOM0_MEM_URL = "http://10.77.0.2:7070/v1/mem/self";
const DOM0_MEM_TIMEOUT_MS = 500;
const DOM0_MEM_STALE_MS = 60_000;

/// On a Monoid Machine, l4h hot-plugs VM memory through dom0's broker in 512 MiB steps, so /proc/meminfo reports only
/// what is plugged now. Dom0's `max` is the pool shared with the `apps` VM, so it is an upper bound.
export function elasticMemoryReader(
  readCmdline: () => Promise<string> = () => readFile("/proc/cmdline", "utf8").catch(() => ""),
  fetchAnswer: () => Promise<unknown> = async () => {
    const res = await fetch(DOM0_MEM_URL, { signal: AbortSignal.timeout(DOM0_MEM_TIMEOUT_MS) });
    if (!res.ok) return null;
    return res.json();
  },
  now: () => number = () => wall.now(),
): () => Promise<unknown> {
  let isVm: Promise<boolean> | null = null;
  let last: { at: number; answer: unknown } | null = null;
  return async () => {
    isVm ??= readCmdline().then(isMonoidStationVm, () => false);
    if (!(await isVm)) return null;
    let answer: unknown = null;
    try {
      answer = await fetchAnswer();
    } catch {
      answer = null;
    }
    const t = now();
    if (isDom0MemAnswer(answer)) {
      last = { at: t, answer };
      return answer;
    }
    return last !== null && t - last.at < DOM0_MEM_STALE_MS ? last.answer : null;
  };
}

const readElasticMemory = elasticMemoryReader();

const host: Host = {
  /// On macOS the CPUs' user, system, idle and nice time (os.cpus, from the same counters as Mach's
  /// HOST_CPU_LOAD_INFO, in ms rather than ticks: the share is the same); elsewhere /proc/stat, read off the main
  /// thread. Not os.cpus on Linux: libuv reads /proc/stat there itself, on the main thread, and each CPU's
  /// cpufreq file besides.
  cpuTicks() {
    if (MACOS) return osCpuTicks();
    return readFile("/proc/stat", "utf8").then(procStatTicks, () => null);
  },
  /// The memory on macOS as Activity Monitor counts it (app, wired and compressed pages, not reclaimable cache), its
  /// swap; elsewhere /proc's. Every command and file at once, none waited on.
  async sample() {
    const said = async (command: string, args: string[]) => {
      try {
        return trim((await run(command, args, { encoding: "utf8", timeout: 3000 })).stdout);
      } catch {
        return null;
      }
    };
    const file = (path: string) => readFile(path, "utf8").catch(() => "");
    const rssOfPs = async () => {
      const kb = parseU64(trim((await said("ps", ["-o", "rss=", "-p", String(process.pid)])) ?? ""));
      return kb === null ? 0 : kb * 1024;
    };
    if (MACOS) {
      const [total, vm, swap, model, boot, version, footprint] = await Promise.all([
        said("sysctl", ["-n", "hw.memsize"]), said("vm_stat", []), said("sysctl", ["-n", "vm.swapusage"]),
        said("sysctl", ["-n", "machdep.cpu.brand_string"]), said("sysctl", ["-n", "kern.boottime"]), said("sw_vers", ["-productVersion"]),
        // Its footprint, as Activity Monitor says it. Resident memory there also counts the system's libraries, shared
        // with every process, and what was freed but not yet taken back: twice or more what it holds.
        said("footprint", ["-f", "bytes", "--noCategories", "-p", String(process.pid)]),
      ]);
      // "{ sec = 1790000000, usec = 0 } ..."
      const sec = boot?.split("sec = ")[1]?.split(",")[0];
      const booted = sec === undefined ? null : /^[+-]?[0-9]+$/.test(trim(sec)) ? Number(trim(sec)) : null;
      const bytes = footprint?.match(/phys_footprint:\s*(\d+)\s*B/)?.[1];
      return {
        memory: macMemoryOf(total, vm, () => swap),
        cpuModel: model ?? "",
        uptimeSec: booted === null ? 0 : Math.max(Math.trunc(wall.now() / 1000) - booted, 0),
        osName: version !== null ? `macOS ${version}` : `macOS (Darwin ${release()})`,
        ownRss: bytes !== undefined ? Number(bytes) : await rssOfPs(),
      };
    }
    const [info, cpus, up, ownRss, dom0] = await Promise.all([file("/proc/meminfo"), file("/proc/cpuinfo"), file("/proc/uptime"), rssOfPs(), readElasticMemory()]);
    const total = fieldOrNull(info, "MemTotal");
    const available = fieldOrNull(info, "MemAvailable");
    const swapTotal = fieldOrNull(info, "SwapTotal");
    const swapFree = fieldOrNull(info, "SwapFree");
    const swapUsedBytes = swapTotal !== null && swapFree !== null && swapFree <= swapTotal ? (swapTotal - swapFree) * 1024 : null;
    const memory = elasticMemory(
      total === null || total <= 0 || available === null || available > total
        ? { totalBytes: (total ?? 0) * 1024, usedBytes: 0, swapUsedBytes, known: false }
        : { totalBytes: total * 1024, usedBytes: (total - available) * 1024, swapUsedBytes },
      dom0,
    );
    let cpuModel = "";
    for (const l of cpus.split("\n")) {
      if (!l.startsWith("model name")) continue;
      const colon = l.indexOf(":", "model name".length);
      if (colon >= 0) { cpuModel = trim(l.slice(colon + 1)); break; }
    }
    const uptime = up === "" ? null : parseF64(firstWord(up));
    return { memory, cpuModel, uptimeSec: uptime === null ? 0 : Math.round(uptime), osName: `${osType()} ${release()}`, ownRss };
  },
};

/// Words as one argument of a POSIX shell's command line.
const quoted = (word: string) => (/^[A-Za-z0-9_./=:@%+-]+$/.test(word) ? word : `'${word.replaceAll("'", `'\\''`)}'`);

/// The processes `pid` started, and theirs: ps's parents.
async function descendants(pid: number): Promise<number[]> {
  let text = "";
  try {
    text = (await run("ps", ["-A", "-o", "pid=,ppid="])).stdout;
  } catch {
    return [];
  }
  const children = new Map<number, number[]>();
  for (const line of text.split("\n")) {
    const [child, parent] = line.trim().split(/\s+/).map(Number);
    if (!Number.isInteger(child) || !Number.isInteger(parent)) continue;
    children.set(parent!, [...(children.get(parent!) ?? []), child!]);
  }
  const out: number[] = [];
  const next = [pid];
  while (next.length > 0) {
    for (const c of children.get(next.pop()!) ?? []) {
      if (out.includes(c)) continue;
      out.push(c);
      next.push(c);
    }
  }
  return out;
}

/// /proc/net/tcp's address (hex, the bytes of each 32-bit word in the machine's order) as an address: 0100007F → 127.0.0.1.
function procAddress(hex: string): string {
  if (/^0+$/.test(hex)) return "*";
  const words = hex.match(/.{8}/g) ?? [];
  const bytes = words.flatMap((w) => (w.match(/../g) ?? []).reverse().map((b) => parseInt(b, 16)));
  if (bytes.length === 4) return bytes.join(".");
  const v4 = bytes.slice(0, 10).every((b) => b === 0) && bytes[10] === 255 && bytes[11] === 255;
  if (v4) return bytes.slice(12).join(".");
  if (bytes.slice(0, 15).every((b) => b === 0) && bytes[15] === 1) return "::1";
  return (hex.match(/.{4}/g) ?? []).join(":");
}

/// Where `pids` listen at `port` by Linux's /proc (no lsof): the listening sockets of the port, those whose inode one of
/// them holds open.
async function procListening(pids: number[], port: number): Promise<string[] | null> {
  const sockets = new Map<string, string>();
  for (const table of ["/proc/net/tcp", "/proc/net/tcp6"]) {
    let text: string;
    try {
      text = await readFile(table, "utf8");
    } catch {
      continue;
    }
    for (const line of text.split("\n").slice(1)) {
      const f = line.trim().split(/\s+/);
      if (f.length < 10 || f[3] !== "0A") continue;
      const [address, hexPort] = f[1]!.split(":");
      if (parseInt(hexPort ?? "", 16) === port) sockets.set(f[9]!, procAddress(address ?? ""));
    }
  }
  if (!(await access("/proc/self/fd").then(() => true, () => false))) return null;
  const found: string[] = [];
  for (const pid of pids) {
    let fds: string[] = [];
    try {
      fds = await readdir(`/proc/${pid}/fd`);
    } catch {
      continue;
    }
    for (const fd of fds) {
      let target = "";
      try {
        target = await readlink(`/proc/${pid}/fd/${fd}`);
      } catch {
        continue;
      }
      const inode = /^socket:\[(\d+)\]$/.exec(target)?.[1];
      const address = inode === undefined ? undefined : sockets.get(inode);
      if (address !== undefined && !found.includes(address)) found.push(address);
    }
  }
  return found;
}

/// std::env::consts::OS for the Unixes Node names otherwise.
const OS: Record<string, string> = { darwin: "macos", linux: "linux", freebsd: "freebsd", openbsd: "openbsd" };

/// macOS's mounts as last read (platform `mounts`), and when; read again in the background once this old. Never read
/// on the thread: `/sbin/mount` once took the thread for as long as a network share it lists did not answer.
let mounted: { at: number; points: string[] } | null = null;
let mounting: Promise<string[]> | null = null;
const MOUNTS_FRESH_MS = 2_000;

/// `/sbin/mount` read off the thread, one read at a time however many ask.
function readMounts(): Promise<string[]> {
  if (mounting) return mounting;
  let thrown = false;
  const read = new Promise<string[]>((resolve) => {
    try {
      execFile("/sbin/mount", { encoding: "utf8" }, (error, out) => {
        mounting = null;
        mounted = { at: wall.now(), points: error ? (mounted?.points ?? []) : parseMounts(out) };
        resolve(mounted.points);
      });
    } catch {
      // Spawning threw before execFile returned: a failed read, kept as one (asked again once stale), none left out.
      thrown = true;
      mounted = { at: wall.now(), points: mounted?.points ?? [] };
      resolve(mounted.points);
    }
  });
  if (!thrown) mounting = read;
  return read;
}

/// Platform.mounts: as last read, none before the first read is in (which this starts); read again in the background
/// once stale.
function mounts(): string[] {
  if (!MACOS) return [];
  if (mounted === null || wall.now() - mounted.at > MOUNTS_FRESH_MS) void readMounts();
  return mounted?.points ?? [];
}

/// Platform.mountsSoon: as mount says them now, read first where not read yet or stale.
async function mountsSoon(): Promise<string[]> {
  if (!MACOS) return [];
  if (mounted !== null && wall.now() - mounted.at <= MOUNTS_FRESH_MS) return mounted.points;
  return readMounts();
}

/// Where Linux's `script` (util-linux's) may be.
const SCRIPTS = ["/usr/bin/script", "/bin/script"];

/// Platform.terminalSoon, given where Linux's `script` is (none: there is no pseudo-terminal to give).
function inTerminal(script: string | undefined, program: string, args: string[], cols: number, rows: number): [string, string[]] | null {
  // The window's size first (script's own is its stdin's, a pipe's: none), then the command in its place.
  const inner = ["/bin/sh", "-c", `stty cols ${cols} rows ${rows} 2>/dev/null; exec "$@"`, "sh", program, ...args];
  // macOS's script refuses a socket for its stdin, and Node's pipes (and macOS's fifos) are sockets: a pipe is put
  // between, `cat` feeding it from ours, ended as the command ends (else it would hold the end up until ours closes).
  if (MACOS) {
    const run = `stty cols ${cols} rows ${rows} 2>/dev/null; exec "$@"`;
    const feed = `exec 3<&0; cat <&3 | { /usr/bin/script -q /dev/null /bin/sh -c '${run}' sh "$@" 3<&-; s=$?; /usr/bin/pkill -P $$ -x cat; exit $s; }`;
    return ["/bin/sh", ["-c", feed, "sh", program, ...args]];
  }
  return script === undefined ? null : [script, ["-qfec", inner.map(quoted).join(" "), "/dev/null"]];
}

export const unix: Platform = {
  os: OS[process.platform] ?? process.platform,
  buildOs: process.platform === "darwin" || process.platform === "linux" ? process.platform : null,
  nativeCache: (env, home) =>
    env.STILLFAIL_NATIVE_CACHE ||
    (MACOS ? join(home, "Library", "Caches", "stillfail-native") : join(env.XDG_CACHE_HOME || join(home, ".cache"), "stillfail-native")),

  exe: (name) => name,
  home: (env) => env.HOME,
  pathOf: (env) => env.PATH ?? "",
  prependPath(env, dir) {
    const rest = env.PATH ?? "";
    return { ...env, PATH: `${dir}${delimiter}${rest}` };
  },
  appendPath(env, dir) {
    const path = env.PATH ?? "";
    if (path.split(delimiter).includes(dir)) return;
    env.PATH = path === "" ? dir : `${path}${delimiter}${dir}`;
  },
  findCommand(name: string, env: Env): Found | null {
    const path = env.PATH;
    if (path === undefined) return null;
    for (const dir of path.split(delimiter)) {
      // An empty entry is the current directory, as split_paths has it.
      const onPath = join(dir === "" ? "." : dir, name);
      if (executable(onPath)) return { onPath, real: real(onPath) ?? onPath };
    }
    return null;
  },
  savedPath: async () => null,
  async findCommandSoon(name: string, env: Env): Promise<Found | null> {
    const path = env.PATH;
    if (path === undefined) return null;
    for (const dir of path.split(delimiter)) {
      const onPath = join(dir === "" ? "." : dir, name);
      const st = await stat(onPath).catch(() => null);
      if (st !== null && st.isFile() && (st.mode & 0o111) !== 0) return { onPath, real: (await realpath(onPath).catch(() => null)) ?? onPath };
    }
    return null;
  },
  userShell(env) {
    if (env.SHELL) return env.SHELL;
    try {
      const user = userInfo();
      // A caller with another HOME (a test or another account) did not supply this user's shell.
      return !env.HOME || env.HOME === user.homedir ? user.shell : null;
    } catch {
      return null;
    }
  },
  runnable: (command, args) => ({ file: command, args }),
  runnableSoon: async (command, args) => ({ file: command, args }),
  posixShell: () => "/bin/sh",
  posixShellSoon: async () => "/bin/sh",
  grouped: (program, args) => [program, args],
  lowered: (program, args, by) => (by === 0 || !niceThere() ? [program, args] : ["/usr/bin/nice", ["-n", String(by), program, ...args]]),
  backgrounded: (program, args) => backgroundedOn(background(), program, args),
  flushing: (dir) => (MACOS ? ["sync", []] : ["sync", ["-f", dir]]),
  makeCommand(path, script) {
    writeFileSync(path, script);
    chmodSync(path, 0o755);
    return path;
  },
  async makeCommandSoon(path, script) {
    // (one there already as it is to be kept: a command running it may hold it)
    const [had, st] = await Promise.all([readFile(path, "utf8").catch(() => null), stat(path).catch(() => null)]);
    if (had === script && st !== null && (st.mode & 0o111) !== 0) return path;
    const tmp = `${path}.${randomUUID()}.tmp`;
    try {
      await writeFile(tmp, script);
      await chmod(tmp, 0o755);
      await rename(tmp, path);
    } catch (error) {
      await rm(tmp, { force: true }).catch(() => {});
      throw error;
    }
    return path;
  },

  signalGroup(pgid, signal) {
    try {
      process.kill(-pgid, signal);
    } catch {
      // ESRCH: the group is already gone.
    }
  },
  signalChildGroup(child: ChildProcess, signal) {
    try {
      if (child.pid !== undefined) process.kill(-child.pid, signal);
    } catch {
      try {
        child.kill(signal);
      } catch {}
    }
  },
  groupAlive(pgid) {
    try {
      process.kill(-pgid, 0);
      return true;
    } catch {
      return false;
    }
  },
  startTimeOf,
  groupOutlivesLeader: true,
  async tcpPortPids(port) {
    try {
      if (MACOS) {
        // lsof -i names the sockets either end of which is on the port: the listener's own end is this process's.
        const { stdout } = await run("lsof", ["-nP", "-a", `-iTCP@127.0.0.1:${port}`, "-sTCP:ESTABLISHED", "-Fp"], { maxBuffer: 1 << 20 });
        return [...new Set(stdout.split("\n").filter((l) => l.startsWith("p")).map((l) => Number(l.slice(1))))].filter((p) => p !== process.pid);
      }
      // Linux: the socket's inode from /proc/net/tcp (local address 0100007F:<port hex>), then whose fd it is.
      const hex = port.toString(16).toUpperCase().padStart(4, "0");
      const inodes = new Set<string>();
      for (const file of ["/proc/net/tcp", "/proc/net/tcp6"]) {
        const text = await readFile(file, "utf8").catch(() => "");
        for (const line of text.split("\n").slice(1)) {
          const f = line.trim().split(/\s+/);
          if (f.length > 9 && f[1]!.endsWith(`:${hex}`) && f[3] === "01") inodes.add(f[9]!);
        }
      }
      if (inodes.size === 0) return [];
      const pids: number[] = [];
      for (const name of await readdir("/proc")) {
        const pid = Number(name);
        if (!Number.isInteger(pid) || pid === process.pid) continue;
        let fds: string[] = [];
        try {
          fds = await readdir(`/proc/${pid}/fd`);
        } catch {
          continue;
        }
        for (const fd of fds) {
          try {
            const link = await readlink(`/proc/${pid}/fd/${fd}`);
            const m = /^socket:\[(\d+)\]$/.exec(link);
            if (m && inodes.has(m[1]!)) {
              pids.push(pid);
              break;
            }
          } catch {}
        }
      }
      return pids;
    } catch {
      return [];
    }
  },
  async groupMemory(pgids) {
    const rss = new Map<number, number>();
    try {
      const { stdout } = await run("ps", ["-axo", "pgid=,rss="]);
      for (const line of stdout.split("\n")) {
        const [pgid, kb] = line.trim().split(/\s+/).map(Number);
        if (pgid !== undefined && kb !== undefined && pgids.includes(pgid)) rss.set(pgid, (rss.get(pgid) ?? 0) + kb);
      }
    } catch {}
    return rss;
  },

  paths: {
    separator: "/",
    sep: "/",
    clean,
    key: (path) => path,
    within: (path, dir) => dir === "/" || path === dir || path.startsWith(`${dir}/`),
    isRootName: () => false,
    rooted: (path) => path.startsWith("/"),
    join: (base, given) => (given.startsWith("/") || base === "" ? given : base.endsWith("/") ? base + given : `${base}/${given}`),
    relativeIn(root, path) {
      // Path::strip_prefix: whole components of the root.
      if (path === root) return "";
      const prefix = root.endsWith("/") ? root : `${root}/`;
      return path.startsWith(prefix) ? path.slice(prefix.length) : null;
    },
    isDrivePath: () => false,
  },

  async disks(home) {
    const found: { name: string; path: string }[] = [];
    for (const mounts of ["/Volumes", join("/media", basename(home)), "/mnt"]) {
      for (const name of (await readdir(mounts).catch(() => [] as string[])).sort((a, b) => collator.compare(a, b))) {
        if (!name.startsWith(".")) found.push({ name, path: join(mounts, name) });
      }
    }
    return found;
  },
  mounts,
  mountsSoon,
  linkRefused: () => false,
  syncsDirectories: true,
  async shareFile(target, link) {
    try {
      const meta = await lstat(link);
      if (meta.isSymbolicLink() && (await readlink(link)) === target) return;
      await unlink(link);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    }
    await symlink(target, link);
  },

  runnerSocketVisible: true,
  runnerSaysLeave: false,

  host,

  async isLauncher(pid) {
    try {
      const command = (await run("ps", ["-p", String(pid), "-o", "command="], { encoding: "utf8" })).stdout;
      return command.includes("stillfail-station");
    } catch {
      return false;
    }
  },
  async askLauncher(pid, op) {
    process.kill(pid, ({ handover: "SIGUSR2", drain: "SIGUSR1", hup: "SIGHUP" } as const)[op]);
  },
  claudeInstall: { program: "/bin/sh", args: ["-c", "curl -fsSL https://claude.ai/install.sh | bash"] },
  /// The Devin CLI's own installer, without the `devin setup` it ends with (a sign-in of the machine's own, which wants
  /// a terminal: here it ends "Login canceled" and the install with it; a profile signs in itself).
  devinInstall: {
    program: "/bin/sh",
    args: ["-c", `set -e; s=$(curl -fsSL https://cli.devin.ai/install.sh); printf '%s\\n' "$s" | sed -E '/^"[^"]*" setup[[:space:]]*$/d' | bash`],
  },
  /// The Antigravity CLI's own installer, as antigravity.google/cli gives it.
  agyInstall: { program: "/bin/sh", args: ["-c", "curl -fsSL https://antigravity.google/cli | bash"] },
  agyBuild: async () => {
    const arch = process.arch === "arm64" ? "arm64" : process.arch === "x64" ? "amd64" : null;
    if (arch === null) return null;
    if (process.platform === "darwin") return `darwin_${arch}`;
    if (process.platform !== "linux") return null;
    // musl told as the installer tells it, by its libc's files.
    const there = (f: string) => access(f).then(() => true, () => false);
    if ((await there("/lib/libc.musl-x86_64.so.1")) || (await there("/lib/libc.musl-aarch64.so.1"))) return null;
    return `linux_${arch}`;
  },
  agyStaging: (env, url) => (env.HOME ? join(env.HOME, ".cache", "antigravity", "staging", url.includes(".tar.gz") ? "agy.tar.gz" : "agy") : null),
  /// In the background of a shell that ends at once: the installer is nobody's child here, and outlives both a handover
  /// (this process is let go) and a restart (the service's processes are stopped).
  installerExt: "sh",
  async startInstaller(script, runDir, env) {
    // A copy: the installer replaces the release it is in. Off the station's thread so file I/O does not hold it up.
    const copy = join(runDir, "install.sh");
    try {
      await copyFile(script, copy);
    } catch {
      return false;
    }
    const shell = `( sh "$1"; echo $? > "$2/update.exit" ) > "$2/update.log" 2>&1 < /dev/null &`;
    return new Promise<boolean>((resolve) => {
      const child = spawn("/bin/sh", ["-c", shell, "sh", copy, runDir], { env, stdio: "ignore", detached: true });
      child.on("error", () => resolve(false));
      child.on("exit", (code) => resolve(code === 0));
      child.unref();
    });
  },
  shimUpdate: async () => null,
  shimUninstall: async () => null,
  async linkCommand(command, dir) {
    const link = join(dir, basename(command));
    if ((await lstat(link).catch(() => null)) !== null) return false;
    // (symlink() fails where something of that name was made meanwhile: nothing is replaced)
    return symlink(command, link).then(() => true, () => false);
  },
  codexStandalone: true,
  nodeBuild(version) {
    const os = process.platform === "darwin" || process.platform === "linux" ? process.platform : null;
    const arch = process.arch === "arm64" || process.arch === "x64" ? process.arch : null;
    if (os === null || arch === null) return null;
    const dist = `node-v${version}-${os}-${arch}`;
    return { dist, archive: `${dist}.tar.gz`, bin: "bin", npm: "npm", tar: "tar" };
  },

  /// macOS: caffeinate against idle sleep, for as long as the station's process is there (-w). Linux: systemd-inhibit
  /// around a `cat` of the station's pipe (none without systemd).
  holdAwake(why) {
    if (MACOS) return holder(spawn("caffeinate", ["-i", "-w", String(process.pid)], { stdio: "ignore" }));
    if (unix.findCommand("systemd-inhibit", process.env) === null) return null;
    return holder(spawn("systemd-inhibit", ["--what=idle:sleep", "--who=still.fail", `--why=${why}`, "--mode=block", "cat"], { stdio: ["pipe", "ignore", "ignore"] }));
  },

  browsers(env) {
    const onPath = (name: string) => unix.findCommand(name, env)?.onPath ?? null;
    return [...new Set(browserPlaces(env, onPath).flatMap((p) => p ?? []))].filter(executable);
  },
  async browsersSoon(env) {
    const onPath = async (name: string) => (await unix.findCommandSoon(name, env))?.onPath ?? null;
    const found = (await Promise.all(browserPlaces(env, onPath))).flatMap((p) => p ?? []);
    const there = await Promise.all([...new Set(found)].map(async (p) => ({ p, is: await executableSoon(p) })));
    return there.flatMap(({ p, is }) => (is ? [p] : []));
  },
  hasDisplay: (env) => MACOS || Boolean(env.DISPLAY || env.WAYLAND_DISPLAY),
  async terminalSoon(program, args, cols, rows) {
    let script: string | undefined;
    if (!MACOS) {
      for (const p of SCRIPTS) {
        if ((await stat(p).catch(() => null)) !== null) {
          script = p;
          break;
        }
      }
    }
    return inTerminal(script, program, args, cols, rows);
  },
  descendants,
  async inputIdleMs() {
    if (!MACOS) return null;
    try {
      return idleOfIoreg((await run("ioreg", ["-c", "IOHIDSystem", "-d", "4", "-r", "-k", "HIDIdleTime"])).stdout);
    } catch {
      return null;
    }
  },
  async memoryPressure() {
    try {
      if (MACOS) {
        const [level, read] = await Promise.all([
          run("sysctl", ["-n", "kern.memorystatus_vm_pressure_level"]).then((r) => r.stdout),
          macPressureReading().catch(() => null),
        ]);
        const trimmed = trim(level);
        // Level 1 can stay normal on a 14 GB VM even with <100 MB free, and level 2 can warn with plenty of reclaimable
        // memory: the memory used says which, and the swap what that leaves out (pressureOfSwap).
        const mem = read?.memory;
        const ofLevel = trimmed !== "1" && trimmed !== "2" || mem === undefined || mem.known === false
          ? pressureOfLevel(level)
          : pressureOfLevel(level, mem.totalBytes - mem.usedBytes, mem.totalBytes);
        return worsePressure(ofLevel, read?.swap ?? null);
      }
      // Pressure is about memory held now, not elastic headroom from dom0. On Linux, MemAvailable still counts active
      // file cache refaulting under reclaim thrashing, so combine it with /proc/pressure/memory (PSI).
      const [info, psi] = await Promise.all([
        readFile("/proc/meminfo", "utf8"),
        readFile("/proc/pressure/memory", "utf8").catch(() => null),
      ]);
      const available = fieldOrNull(info, "MemAvailable");
      const total = fieldOrNull(info, "MemTotal");
      return worsePressure(pressureOfAvailable(available, total), pressureOfMemoryPsi(psi, available, total));
    } catch {
      return null;
    }
  },
  async processTable(exact) {
    let table;
    try {
      table = parsePs((await run("ps", ["-axo", "pid=,ppid=,pgid=,rss=,comm="], { maxBuffer: 16 << 20 })).stdout);
    } catch {
      return null;
    }
    // macOS: resident memory leaves out what is compressed or swapped out, which is most of a process that grew past
    // the memory there is; top's MEM is its footprint, as Activity Monitor says it.
    if (exact && MACOS) {
      try {
        const mem = parseTopMem((await run("top", ["-l", "1", "-stats", "pid,mem", "-n", "100000"], { maxBuffer: 16 << 20 })).stdout);
        for (const p of table) p.bytes = mem.get(p.pid) ?? p.bytes;
      } catch {}
    }
    return table;
  },
  async cwds(pids) {
    const out = new Map<number, string>();
    if (pids.length === 0) return out;
    if (!MACOS) {
      for (const pid of pids) {
        try {
          out.set(pid, await readlink(`/proc/${pid}/cwd`));
        } catch {}
      }
      return out;
    }
    let text = "";
    try {
      text = (await run("lsof", ["-a", "-d", "cwd", "-p", pids.join(","), "-Fpn"])).stdout;
    } catch (e) {
      // lsof exits 1 when one of them is gone; what it found is still said.
      text = (e as { stdout?: string }).stdout ?? "";
    }
    let pid: number | null = null;
    for (const line of text.split("\n")) {
      if (line.startsWith("p")) pid = Number(line.slice(1));
      else if (line.startsWith("n") && pid !== null) out.set(pid, line.slice(1));
    }
    return out;
  },
  async listening(pids, port) {
    if (pids.length === 0) return [];
    try {
      const { stdout } = await run("lsof", ["-nP", "-a", "-p", pids.join(","), `-iTCP:${port}`, "-sTCP:LISTEN", "-Fn"]);
      return parseLsof(stdout, port);
    } catch (e) {
      const error = e as NodeJS.ErrnoException & { stdout?: string; code?: unknown };
      // lsof says nothing found by its exit 1.
      if (typeof error.code === "number" && error.code === 1) return parseLsof(error.stdout ?? "", port);
      return MACOS ? null : await procListening(pids, port);
    }
  },
  async commands(pids) {
    if (pids.length === 0) return [];
    try {
      return (await run("ps", ["-o", "comm=", "-p", pids.join(",")])).stdout.split("\n").map((l) => l.trim()).filter((l) => l !== "");
    } catch {
      return [];
    }
  },
  async echoes(pid) {
    try {
      const tty = (await run("ps", ["-o", "tty=", "-p", String(pid)])).stdout.trim();
      if (tty === "" || tty.startsWith("?") || tty === "??") return null;
      const { stdout } = await run("stty", [MACOS ? "-f" : "-F", `/dev/${tty}`, "-a"]);
      // A password is read a line at a time without echo; a program reading keys one by one (a menu, a Y/n) turns off
      // both line mode and echo, and draws what it shows itself: that is no secret.
      if (/(^|\s)-echo(\s|$)/.test(stdout) && !/(^|\s)-icanon(\s|$)/.test(stdout)) return false;
      return /(^|\s)-?echo(\s|$)/.test(stdout) ? true : null;
    } catch {
      return null;
    }
  },

  hasKeychain: MACOS,
  trash: MACOS ? "finder" : "freedesktop",
  hasQuickLook: MACOS,
  hasFolderPermissions: MACOS,
  hasSpotlight: MACOS,
  hasUnixSockets: true,
  desktopScreen: MACOS ? "helper" : process.platform === "linux" ? "x11" : null,
};
