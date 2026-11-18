// The station's operations and its platform in MoonBit (station/mb src/ops_platform: reader `--builder
// harness-ops-platform`) held to the TypeScript they port, on the same inputs: src/platform/ (what macOS', Linux's and
// Windows' commands and files say, the commands made, Windows' paths and shims), src/ops/ (paths, config, the
// launcher's channel, the logs, a command's output, the station's memory and its upkeep), src/resources/, the files and
// skills a search lists (src/search/), and what src/read/ makes of its views. Each case is given both whole; their
// outcomes must be the same. What a module keeps to itself is taken from its source as it is (`privateOf`), run on a
// `process` of the machine the case says, so the macOS and Linux sides are both held on any machine.
import assert from "node:assert/strict";
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, renameSync, rmSync, symlinkSync, utimesSync, writeFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
import { tmpdir } from "node:os";
import { join, posix, win32 } from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath, pathToFileURL } from "node:url";
import vm from "node:vm";
import { after, test } from "node:test";
import { mbReaderBinary } from "../src/read/mb-reader.ts";
import * as text from "../src/platform/text.ts";
import { cpuShare } from "../src/platform/cpu-share.ts";
import { treeOf } from "../src/platform/index.ts";
import { backgroundedOn } from "../src/platform/unix.ts";
import { cmdPath, gitShell, gitShellSoon, readShim, savedPathOf, wingetPackage, windowsUpdateScript } from "../src/platform/windows.ts";
import * as paths from "../src/ops/paths.ts";
import { stationVersion } from "../src/ops/version.ts";
import { Own } from "../src/ops/own.ts";
import { unanswered } from "../src/ops/unanswered.ts";
import { diskEvery, diskSoft, diskTier } from "../src/ops/disk.ts";
import { heldBy } from "../src/ops/held.ts";
import { askedBy, longestWaits, noWaits, waited } from "../src/ops/waits.ts";
import { langOf, tr } from "../src/ops/i18n.ts";
import { branded, productOf } from "../../client/i18n/brand.ts";
import { makerOf, modelName } from "../src/ops/model-name.ts";
import { agentEnv, checkAgentEnv, keepLocal, maskValue, parseEnvText, secretValue } from "../src/ops/agent-env.ts";
import { healthOf, workingOf } from "../src/ops/health.ts";
import { flag, portsToTry, positionals } from "../src/ops/files.ts";
import * as out from "../src/ops/command-output.ts";
import { answer as loopbackAnswer, langOfBrowser, moved } from "../src/ops/loopback.ts";

const binary = mbReaderBinary();
const skip = binary === null ? "the MoonBit program (stillfail-reader) is not built here" : false;
const SRC = fileURLToPath(new URL("../src/", import.meta.url));
const ROOT = fileURLToPath(new URL("../../", import.meta.url));

const dirs: string[] = [];
const fresh = (what: string) => {
  const dir = mkdtempSync(join(tmpdir(), `ops-platform-${what}-`));
  dirs.push(dir);
  return dir;
};

let program: { child: ChildProcessWithoutNullStreams; next: (line: string) => Promise<any> } | null = null;
/// The program, started once: a case a line, its answer a line.
function harness() {
  if (program !== null) return program;
  const shell = fresh("shell");
  const child = spawn(binary!, ["--builder", "harness-ops-platform", "--shell-dir", shell], { stdio: ["pipe", "pipe", "pipe"] });
  const waiting: ((line: string) => void)[] = [];
  createInterface({ input: child.stdout }).on("line", (line) => waiting.shift()?.(line));
  let stderr = "";
  child.stderr.on("data", (d) => (stderr += d));
  child.on("exit", (code) => { for (const w of waiting.splice(0)) w(JSON.stringify({ error: `the program ended (${code}): ${stderr}` })); });
  program = {
    child,
    next: (line) => new Promise((resolve) => {
      waiting.push((answer) => resolve(JSON.parse(answer)));
      child.stdin.write(`${line}\n`);
    }),
  };
  return program;
}
after(() => {
  program?.child.stdin.end();
  for (const dir of dirs) rmSync(dir, { recursive: true, force: true });
});

/// What MoonBit says of `c` (its `ok`, or the words it failed with).
async function mb(c: Record<string, unknown>): Promise<any> {
  const answer = await harness().next(JSON.stringify(c));
  if ("error" in answer) throw new Error(`MoonBit: ${answer.error}`);
  return answer.ok;
}

/// A JSON round trip: what both sides are compared as (a value of another realm too).
const plain = (v: unknown) => (v === undefined ? null : JSON.parse(JSON.stringify(v)));
/// A Map as the harness says it: its entries in their order.
const entries = (m: Map<unknown, unknown>) => [...m.entries()];

/// Both sides the same for `c`: MoonBit's answer and `expected` (the TypeScript's).
async function same(c: Record<string, unknown>, expected: unknown, label = JSON.stringify(c).slice(0, 160)) {
  assert.deepEqual(await mb(c), plain(expected), label);
}

// ── what a module keeps to itself, as its source has it ──

const loaded = new Map<string, Record<string, any>>();
/// The names a module of src/ declares at its top, private ones too, from its source as it is: its imports bound to
/// the modules themselves, run on `process` (a machine's own: `darwin` or `linux` where the case says).
async function privateOf(file: string, given: Record<string, unknown> = {}, key = ""): Promise<Record<string, any>> {
  const k = `${file}|${key}`;
  const had = loaded.get(k);
  if (had !== undefined) return had;
  let source = readFileSync(join(SRC, file), "utf8");
  const scope: Record<string, unknown> = {};
  const base = pathToFileURL(join(SRC, file));
  for (const m of source.matchAll(/^import\s+(type\s+)?([\s\S]*?)\s+from\s+"([^"]+)"(?:\s+with\s+\{[^}]*\})?;?$/gm)) {
    if (m[1]) continue;
    const spec = m[3]!;
    const mod = await import(spec.startsWith(".") ? new URL(spec, base).href : spec);
    let clause = m[2]!.trim();
    const named = /\{([\s\S]*)\}/.exec(clause);
    if (named) {
      for (const part of named[1]!.split(",").map((p) => p.trim()).filter((p) => p !== "" && !/^type\s+(?!as\b)/.test(p))) {
        const [from, as] = part.split(/\s+as\s+/);
        scope[(as ?? from)!.trim()] = mod[from!.trim()];
      }
      clause = clause.replace(named[0], "").replace(/,\s*$/, "").trim();
    }
    const star = /\*\s+as\s+(\w+)/.exec(clause);
    if (star) scope[star[1]!] = mod;
    else if (clause !== "") scope[clause.replace(/,$/, "").trim()] = mod.default ?? mod;
  }
  source = source
    .replace(/^import\s[\s\S]*?from\s+"[^"]+"(?:\s+with\s+\{[^}]*\})?;?$/gm, "")
    .replace(/^export\s+\{[^}]*\}(\s+from\s+"[^"]+")?;?$/gm, "")
    .replace(/^export\s+(default\s+)?/gm, "");
  // What the case gives in place of a module's own (its `run`, a helper): its declaration renamed, so the module's
  // code reaches the one given.
  for (const name of Object.keys(given)) {
    source = source.replace(new RegExp(`^((?:async\\s+)?(?:function\\*?|const|let|class)\\s+)${name.replace(/\$/g, "\\$")}\\b`, "m"), `$1__shadowed_${name}`);
  }
  const names = [...source.matchAll(/^(?:async\s+)?(?:function\*?|const|let|class)\s+([A-Za-z_$][\w$]*)/gm)].map((m) => m[1]!);
  const listed = [...new Set(names)].map((n) => `${n}: typeof ${n} === "undefined" ? undefined : ${n}`).join(", ");
  const js = `${stripTypeScriptTypes(source, { mode: "transform" })}\n;({ ${listed} })`;
  const context = vm.createContext({
    ...scope, Buffer, URL, URLSearchParams, TextDecoder, TextEncoder, setTimeout, clearTimeout, setImmediate, console, process, AbortSignal, AbortController,
    ...given,
  });
  const got = vm.runInContext(js, context);
  loaded.set(k, got);
  return got;
}
/// platform/windows.ts as it runs on Windows: node:path's `join`, `dirname` and `delimiter` Windows' own.
const winOf = (given: Record<string, unknown> = {}, key = "") =>
  privateOf("platform/windows.ts", { join: win32.join, dirname: win32.dirname, delimiter: win32.delimiter, ...given }, `win-${key}`);
/// Node's `process` as a machine of `os` has it.
const processOn = (os: string) => new Proxy(process, { get: (t, p) => (p === "platform" ? os : (t as any)[p]) });

// ── platform/text.ts ──

const WORDS = ["", "  a  b\tc ", "\u00a0x\u3000y\u2028", "\ufeffz", "+12", "12a", "-3", "007", "1.5", ".5", "1e3", "1.", "e5", "+.5e-2", "abc", " 9 "];
const PS = `  PID  PPID  PGID   RSS COMM
    1     0     1  1024 /sbin/launchd
  321     1   321  2048 /Applications/X.app/Contents/MacOS/X --flag
  400   321   321     0
  401   321   321    12 a\tb
 bad line
  402  400   400  99 名前 with spaces  \n`;
const TOP = `Processes: 500 total
PID    MEM
1      27M
2      3056K+
3      1.2G-
4      12B
5      2T
6      1.5Q
x      1M
3      9M`;
const VM_STAT = `Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free:                               12345.
Anonymous pages:                         400000.
Pages purgeable:                           1000.
Pages wired down:                        200000.
Pages occupied by compressor:             50000.`;
const MEMINFO = "MemTotal:       16384000 kB\nMemFree:  100 kB\nMemAvailable:    8192000 kB\nSwapTotal: 2048 kB\nSwapFree: 1024 kB\n";

test("platform/text.ts: what commands and files say", { skip }, async () => {
  for (const s of WORDS) {
    await same({ fn: "trim", s }, text.trim(s));
    await same({ fn: "splitWords", s }, text.splitWords(s));
    await same({ fn: "firstWord", s }, text.firstWord(s));
    await same({ fn: "parseU64", s }, text.parseU64(s));
    await same({ fn: "parseF64", s }, text.parseF64(s));
  }
  for (const [a, t] of [[null, 10], [5, null], [0.5, 10], [0.3, 10], [5, 10], [11, 10], [-1, 10], [1, 0], [0.99, 10]] as const) {
    await same({ fn: "pressureOfAvailable", available: a, total: t }, text.pressureOfAvailable(a, t));
    for (const level of ["1", "2", "4", " 2\n", "3", ""]) await same({ fn: "pressureOfLevel", level, available: a, total: t }, text.pressureOfLevel(level, a, t));
  }
  await same({ fn: "parsePs", text: PS }, text.parsePs(PS));
  await same({ fn: "parseTopMem", text: TOP }, entries(text.parseTopMem(TOP)));
  for (const label of ["Pages free", "Anonymous pages", "Pages wired down", "Nope", "Mach Virtual Memory Statistics"]) await same({ fn: "fieldOrNull", text: VM_STAT, label }, text.fieldOrNull(VM_STAT, label));
  for (const label of ["MemTotal", "MemAvailable", "SwapFree"]) await same({ fn: "fieldOrNull", text: MEMINFO, label }, text.fieldOrNull(MEMINFO, label));
  for (const stat of ["cpu  100 5 50 1000 20 0 3 0 0 0\ncpu0 1 2 3 4", "cpu 1 2 3", "intr 5", "cpu  a b c d e\n", "cpu  1 2 3 4 5 6 7 8 9 10 11"]) await same({ fn: "procStatTicks", text: stat }, text.procStatTicks(stat));
  const lsof = "p123\nn127.0.0.1:8085\nn[::1]:8085\nn*:8085\nn*:8086\nn127.0.0.1:8085\nx\nnnoport\n";
  for (const port of [8085, 8086, 1]) await same({ fn: "parseLsof", text: lsof, port }, text.parseLsof(lsof, port));
  for (const io of ['  "HIDIdleTime" = 1234567890\n', '"HIDIdleTime"=5', "none", '"HIDIdleTime" = x "HIDIdleTime" = 77']) await same({ fn: "idleOfIoreg", text: io }, text.idleOfIoreg(io));
  const mounts = [
    "/dev/disk3s1s1 on / (apfs, sealed, local, read-only, journaled)",
    "devfs on /dev (devfs, local, nobrowse)",
    "/dev/disk3s6 on /System/Volumes/VM (apfs, local, noexec, journaled, noatime, nobrowse)",
    "map auto_home on /System/Volumes/Data/home (autofs, automounted, nobrowse)",
    "//user@server/share on /Volumes/share (smbfs, nodev, nosuid, mounted by user)",
    "x on /Users/me/OrbStack (nfs, nodev, nosuid, mounted by me)",
    "weird on /a (b) on /c (d)",
    "nothing here",
    "y on /with (paren) (x)",
  ].join("\n");
  await same({ fn: "parseMounts", text: mounts }, text.parseMounts(mounts));
  for (const [a, b] of [[[1, 10], [5, 20]], [[1, 10], [1, 10]], [[10, 10], [5, 20]], [[0, 0], [100, 50]], [[0, 0], [5, 5]]] as const) {
    await same({ fn: "cpuShare", a, b }, cpuShare(a as [number, number], b as [number, number]));
  }
  const table = [
    { pid: 1, ppid: 0, pgid: 1, bytes: 1, command: "a" }, { pid: 2, ppid: 1, pgid: 2, bytes: 1, command: "b" }, { pid: 3, ppid: 1, pgid: 2, bytes: 1, command: "c" },
    { pid: 4, ppid: 4, pgid: 4, bytes: 1, command: "self" }, { pid: 5, ppid: 3, pgid: 2, bytes: 1, command: "d" },
  ];
  await same({ fn: "treeOf", table }, entries(treeOf(table).children));
});

// ── Node's path.win32 and path.posix, as windows.ts and the rest use them ──

const WIN_PATHS = [
  "", "C:", "C:\\", "c:/Users/x/../y/./z", "C:\\Users\\x\\", "\\\\server\\share", "\\\\server\\share\\a\\..\\b", "\\\\server", "\\\\.\\pipe\\x",
  "\\\\?\\C:\\a\\..\\b", "//a/b/c", "\\a\\b", "/a/b", "a\\b\\..\\..\\..", "C:a\\b", "a:b", "x:", "\\", "/", ".", "..", "C:\\..\\..", "D:\\x\\",
  "C:\\Program Files\\Git\\cmd", "C:\\Windows\\System32", "名前\\x", "C:\\a\\b", "c:\\A\\B\\c",
];

test("Node's path.win32 and path.posix as the ports have them", { skip }, async () => {
  const cwd = process.cwd();
  for (const p of WIN_PATHS) {
    for (const to of ["C:\\a\\b\\c", "c:\\A\\x", "\\\\server\\share\\a", "D:\\", "C:\\a", "a\\b"]) {
      const parts = [p, "x", "", "..\\y"];
      await same({ fn: "win32", path: p, to, cwd, parts }, {
        resolve: win32.resolve(p), normalize: win32.normalize(p), dirname: win32.dirname(p), isAbsolute: win32.isAbsolute(p), join: win32.join(...parts), relative: win32.relative(p, to),
      }, `win32 ${JSON.stringify([p, to])}`);
    }
  }
  for (const p of ["", "/", "a/b/../c", "/a//b/./c/", "../..", "./", "a/../../b", "/..", "//x"]) {
    await same({ fn: "posix", path: p, cwd, parts: [p, "q", "", "../r"] }, { normalize: posix.normalize(p), join: posix.join(p, "q", "", "../r"), resolve: posix.resolve(p) });
  }
});

// ── platform/unix.ts ──

test("platform/unix.ts: the commands it makes and what it reads, macOS and Linux", { skip }, async () => {
  for (const how of [{ kind: "taskpolicy" }, { kind: "ionice", ionice: "/usr/bin/ionice", nice: "/usr/bin/nice" }, { kind: "nice", nice: "/bin/nice" }, { kind: "none" }] as const) {
    await same({ fn: "backgroundedOn", how, program: "/bin/x", args: ["a", "b c"] }, backgroundedOn(how, "/bin/x", ["a", "b c"]));
  }
  for (const os of ["darwin", "linux"]) {
    const fakeProcess = processOn(os);
    for (const [there, real] of [
      [["/usr/sbin/taskpolicy", "/usr/bin/nice"], {}], [["/usr/bin/nice"], {}], [["/bin/ionice", "/bin/nice"], {}], [["/usr/bin/ionice", "/usr/bin/nice"], { "/usr/bin/ionice": "/bin/busybox" }],
      [["/usr/bin/ionice", "/bin/ionice", "/bin/nice"], { "/usr/bin/ionice": "/x/busybox" }], [[], {}],
    ] as const) {
      const m = await privateOf("platform/unix.ts", {
        process: fakeProcess, existsSync: (p: string) => (there as readonly string[]).includes(p), realpathSync: (p: string) => (real as Record<string, string>)[p] ?? p,
      }, `${os}-${JSON.stringify([there, real])}`);
      await same({ fn: "backgroundFound", mac: os === "darwin", there, real }, m.background());
    }
  }
  const m = await privateOf("platform/unix.ts");
  for (const p of ["", "/", "a/b", "/a/../../b/./c//", "/x/y/.."]) await same({ fn: "unixClean", path: p }, m.clean(p));
  const now = 1_790_000_000_000;
  for (const etime of ["", "05:03", "1:02:03", "2-01:02:03", "x-1:1", "1:2:3:4", "7", " 00:01 "]) {
    const ps = await privateOf("platform/unix.ts", { run: async () => ({ stdout: etime }), wall: { now: () => now } }, `etime-${etime}`);
    await same({ fn: "startTimeOfEtime", text: etime, now }, await ps.startTimeOf(1));
  }
  for (const [total, vm, swap] of [
    ["17179869184", VM_STAT, "total = 2048.00M  used = 512.25M  free = 1535.75M  (encrypted)"], ["17179869184", VM_STAT, null], ["0", VM_STAT, null],
    [null, null, null], ["17179869184", "Mach (page size of x bytes)", null], ["1", VM_STAT, "used = abcM"],
  ] as const) {
    await same({ fn: "macMemoryOf", total, vm, swap }, m.macMemoryOf(total, vm, () => swap));
  }
  for (const [info, cpus, up] of [
    [MEMINFO, "processor : 0\nmodel name\t: Intel(R) Xeon(R)  \nmodel name : second", "12345.67 54321.00"], ["", "", ""], ["MemTotal: 10 kB\nMemAvailable: 20 kB\n", "model name", "x y"],
  ]) {
    const lm = await privateOf("platform/unix.ts", {
      process: processOn("linux"), readFile: async (p: string) => ({ "/proc/meminfo": info, "/proc/cpuinfo": cpus, "/proc/uptime": up } as Record<string, string>)[p] ?? "",
      run: async () => ({ stdout: "100\n" }),
    }, `linux-${info}-${cpus}-${up}`);
    const s = await lm.host.sample();
    await same({ fn: "linuxSample", info, cpus, up }, { memory: s.memory, cpuModel: s.cpuModel, uptimeSec: s.uptimeSec });
  }
  for (const [boot, footprint] of [["{ sec = 1789990000, usec = 0 } Thu Sep", "phys_footprint: 123456 B\nphys_footprint_peak: 9 B"], [null, null], ["{ sec = abc, usec", "phys_footprint:  77  KB"]] as const) {
    const mm = await privateOf("platform/unix.ts", {
      process: processOn("darwin"), wall: { now: () => now },
      run: async (cmd: string, args: string[]) => {
        const said: Record<string, string | null> = { "kern.boottime": boot, footprint, "hw.memsize": "1", "machdep.cpu.brand_string": "M", "-productVersion": "15", "vm.swapusage": "" };
        const key = cmd === "footprint" ? "footprint" : args.at(-1)!;
        const v = said[key] ?? (cmd === "ps" ? "4" : null);
        if (v === null) throw new Error("no");
        return { stdout: v };
      },
    }, `mac-${boot}-${footprint}`);
    const s = await mm.host.sample();
    await same({ fn: "macBootAndFootprint", boot, footprint, now }, { uptimeSec: s.uptimeSec, footprint: footprint === null || !/phys_footprint:\s*(\d+)\s*B/.test(footprint) ? null : s.ownRss });
  }
  for (const word of ["plain", "a b", "it's", "", "$HOME", "x=y:z@w%+-/.", "名"]) await same({ fn: "quoted", word }, m.quoted(word));
  const ps = "  1 0\n  2 1\n 3 2\n 4 1\n 5 9\n x y\n 6 4\n 2 3\n";
  for (const pid of [1, 2, 9, 42]) {
    const dm = await privateOf("platform/unix.ts", { run: async () => ({ stdout: ps }) }, "desc");
    await same({ fn: "descendants", text: ps, pid }, await dm.descendants(pid));
  }
  for (const hex of ["0100007F", "00000000", "0000000000000000FFFF00000100007F", "00000000000000000000000001000000", "B80D01200000000000000000000000AB", "12345678", ""]) await same({ fn: "procAddress", hex }, m.procAddress(hex));
  const tcp = `  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 0100007F:1F95 00000000:0000 0A 00000000:00000000 00:00000000 00000000   501        0 12345 1
   1: 00000000:1F95 00000000:0000 0A 00000000:00000000 00:00000000 00000000   501        0 12346 1
   2: 0100007F:1F95 0100007F:C350 01 00000000:00000000 00:00000000 00000000   501        0 12347 1
   3: 0100007F:1F96 00000000:0000 0A 00000000:00000000 00:00000000 00000000   501        0 12348 1`;
  const tcp6 = `  sl  local_address remote st
   0: 00000000000000000000000001000000:1F95 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000 501 0 22222 1`;
  for (const port of [8085, 8086, 1]) {
    const lm = await privateOf("platform/unix.ts", {
      readFile: async (p: string) => ({ "/proc/net/tcp": tcp, "/proc/net/tcp6": tcp6 } as Record<string, string>)[p] ?? "",
      access: async () => { throw new Error("no fd"); },
    }, "procListening");
    // (the sockets alone: no /proc/self/fd here)
    assert.equal(await lm.procListening([1], port), null);
    const sockets = new Map<string, string>();
    for (const t of [tcp, tcp6]) for (const line of t.split("\n").slice(1)) {
      const f = line.trim().split(/\s+/);
      if (f.length < 10 || f[3] !== "0A") continue;
      const [address, hexPort] = f[1]!.split(":");
      if (parseInt(hexPort ?? "", 16) === port) sockets.set(f[9]!, m.procAddress(address ?? ""));
    }
    await same({ fn: "procListeningSockets", tables: [tcp, tcp6], port }, entries(sockets));
    const inodes = new Set<string>();
    const hex = port.toString(16).toUpperCase().padStart(4, "0");
    for (const t of [tcp, tcp6]) for (const line of t.split("\n").slice(1)) {
      const f = line.trim().split(/\s+/);
      if (f.length > 9 && f[1]!.endsWith(`:${hex}`) && f[3] === "01") inodes.add(f[9]!);
    }
    await same({ fn: "tcpPortInodes", tables: [tcp, tcp6], port }, [...inodes]);
  }
  for (const target of ["socket:[123]", "socket:[]", "pipe:[1]", "socket:[12a]"]) await same({ fn: "socketInode", target }, /^socket:\[(\d+)\]$/.exec(target)?.[1] ?? null);
  const lsofP = "p100\nf1\np200\np100\npx\n";
  for (const own of [100, 300]) {
    const um = await privateOf("platform/unix.ts", { process: new Proxy(processOn("darwin"), { get: (t, p) => (p === "pid" ? own : (t as any)[p]) }), run: async () => ({ stdout: lsofP }) }, `tcpPortPids-${own}`);
    await same({ fn: "lsofPids", text: lsofP, own }, await um.unix.tcpPortPids(8080));
  }
  const psG = " 10 100\n 10 50\n 20 7\n 30 x\n\n 20\n";
  const gm = await privateOf("platform/unix.ts", { run: async () => ({ stdout: psG }) }, "groupMemory");
  await same({ fn: "groupMemoryOfPs", text: psG, pgids: [10, 20, 30, 40] }, entries(await gm.unix.groupMemory([10, 20, 30, 40])));
  for (const os of ["darwin", "linux"]) {
    for (const script of [undefined, "/usr/bin/script"]) {
      const tm = await privateOf("platform/unix.ts", { process: processOn(os) }, `term-${os}`);
      await same({ fn: "inTerminal", mac: os === "darwin", script, program: "gh", args: ["auth", "login", "it's"], cols: 120, rows: 40 }, tm.inTerminal(script, "gh", ["auth", "login", "it's"], 120, 40));
    }
  }
  for (const [p, d] of [["/a/b", "/a"], ["/a", "/a"], ["/ab", "/a"], ["/x", "/"], ["/a/", "/a"], ["rel", "/a/"], ["/a/b", ""]]) {
    await same({ fn: "unixPaths", path: p, dir: d }, { within: m.unix.paths.within(p, d), join: m.unix.paths.join(d, p), relativeIn: m.unix.paths.relativeIn(d, p) });
  }
  for (const os of ["darwin", "linux"]) {
    const om = await privateOf("platform/unix.ts", { process: processOn(os) }, `os-${os}`);
    for (const env of [{}, { STILLFAIL_NATIVE_CACHE: "/c" }, { XDG_CACHE_HOME: "/x" }, { XDG_CACHE_HOME: "" }]) await same({ fn: "unixNativeCache", mac: os === "darwin", env, home: "/home/u" }, om.unix.nativeCache(env, "/home/u"));
    await same({ fn: "unixFlushing", mac: os === "darwin", dir: "/d" }, om.unix.flushing("/d"));
    for (const env of [{ HOME: "/h" }, {}]) {
      const found: Record<string, string> = { "google-chrome": "/usr/bin/google-chrome", chromium: "/snap/bin/chromium" };
      const bm = await privateOf("platform/unix.ts", { process: processOn(os) }, `browsers-${os}`);
      await same({ fn: "unixBrowserPlaces", mac: os === "darwin", env, found }, [...new Set(bm.browserPlaces(env, (n: string) => found[n] ?? null).flatMap((p: string | null) => p ?? []))]);
    }
  }
  for (const env of [{ PATH: "/a:/b" }, {}, { PATH: "" }]) {
    await same({ fn: "unixPrependPath", env, dir: "/new" }, m.unix.prependPath(env, "/new"));
    for (const dir of ["/b", "/c"]) {
      const e: Record<string, string> = { ...(env as Record<string, string>) };
      m.unix.appendPath(e, dir);
      await same({ fn: "unixAppendPath", env, dir }, e);
    }
  }
  for (const [by, nice] of [[0, true], [10, true], [5, false]] as const) {
    const nm = await privateOf("platform/unix.ts", { existsSync: () => nice }, `nice-${nice}`);
    await same({ fn: "unixLowered", program: "p", args: ["x"], by, nice }, nm.unix.lowered("p", ["x"], by));
  }
  for (const env of [{ HOME: "/h" }, {}, { HOME: "" }]) for (const url of ["https://x/agy.tar.gz", "https://x/agy"]) await same({ fn: "unixAgyStaging", env, url }, m.unix.agyStaging(env, url));
  for (const platform of ["darwin", "linux", "win32", "freebsd"]) for (const arch of ["arm64", "x64", "ia32"]) {
    const nb = await privateOf("platform/unix.ts", { process: new Proxy(process, { get: (t, p) => (p === "platform" ? platform : p === "arch" ? arch : (t as any)[p]) }) }, `nb-${platform}-${arch}`);
    await same({ fn: "unixNodeBuild", version: "24.1.0", platform, arch }, nb.unix.nodeBuild("24.1.0"));
    for (const musl of [false, true]) {
      const ab = await privateOf("platform/unix.ts", {
        process: new Proxy(process, { get: (t, p) => (p === "platform" ? platform : p === "arch" ? arch : (t as any)[p]) }),
        access: async (f: string) => { if (!musl || !f.includes("musl")) throw new Error("no"); },
      }, `ab-${platform}-${arch}-${musl}`);
      await same({ fn: "unixAgyBuild", platform, arch, musl }, await ab.unix.agyBuild());
    }
    await same({ fn: "unixOs", platform }, ({ darwin: "macos", linux: "linux", freebsd: "freebsd", openbsd: "openbsd" } as Record<string, string>)[platform] ?? platform);
  }
  const cw = "p10\nfcwd\nn/a/b\np11\nn/c\nn/d\nnorphan\n";
  const cm = await privateOf("platform/unix.ts", { process: processOn("darwin"), run: async () => ({ stdout: cw }) }, "cwds");
  await same({ fn: "lsofCwds", text: cw }, entries(await cm.unix.cwds([10, 11])));
  const comm = " zsh\n\n/bin/x  \n";
  const com = await privateOf("platform/unix.ts", { run: async () => ({ stdout: comm }) }, "comm");
  await same({ fn: "psCommands", text: comm }, await com.unix.commands([1]));
  for (const [tty, stty] of [["ttys001", "speed 9600; -echo icanon"], ["ttys001", "lflags: -icanon -echo"], ["ttys001", "echo icanon"], ["??", "x"], ["", "x"], ["pts/1", "nothing"], ["pts/1", "-echoe -echok"]]) {
    const em = await privateOf("platform/unix.ts", { run: async (c: string) => ({ stdout: c === "ps" ? tty : stty }) }, `echo-${tty}-${stty}`);
    await same({ fn: "echoesOf", tty, stty }, await em.unix.echoes(1));
  }
  for (const op of ["handover", "drain", "hup"]) await same({ fn: "unixLauncherSignal", op }, ({ handover: "SIGUSR2", drain: "SIGUSR1", hup: "SIGHUP" } as Record<string, string>)[op]);
  for (const command of ["/x/stillfail-station run", "node"]) {
    const lm = await privateOf("platform/unix.ts", { run: async () => ({ stdout: command }) }, `launcher-${command}`);
    await same({ fn: "unixIsLauncher", command }, await lm.unix.isLauncher(1));
  }
  await same({ fn: "unixInstalls" }, { claudeInstall: m.unix.claudeInstall, devinInstall: m.unix.devinInstall, agyInstall: m.unix.agyInstall });
  await same({ fn: "unixInstallerShell" }, `( sh "$1"; echo $? > "$2/update.exit" ) > "$2/update.log" 2>&1 < /dev/null &`);
  for (const [env, userHome, userShell] of [[{ SHELL: "/bin/zsh" }, "/h", "/bin/bash"], [{ HOME: "/h" }, "/h", "/bin/bash"], [{ HOME: "/other" }, "/h", "/bin/bash"], [{}, "/h", "/bin/fish"]] as const) {
    const sm = await privateOf("platform/unix.ts", { userInfo: () => ({ homedir: userHome, shell: userShell }) }, `shell-${JSON.stringify(env)}`);
    await same({ fn: "unixUserShell", env, userHome, userShell }, sm.unix.userShell(env));
  }
});

// ── platform/windows.ts ──

const WIN_ENV = {
  Path: "C:\\Program Files\\Git\\cmd;C:\\Windows\\System32;;C:\\Tools", USERPROFILE: "C:\\Users\\张三", LOCALAPPDATA: "C:\\Users\\张三\\AppData\\Local",
  ProgramFiles: "C:\\Program Files", "ProgramFiles(x86)": "C:\\Program Files (x86)", PATHEXT: ".EXE;.CMD", ComSpec: "C:\\Windows\\system32\\cmd.exe",
};

test("platform/windows.ts: Windows' paths, shims, PATH and scripts", { skip }, async () => {
  const w = await winOf();
  for (const env of [WIN_ENV, { PATH: "x" }, { path: "" }, {}]) await same({ fn: "winPathOf", env }, w.pathOf(env));
  for (const p of ["C:\\plain\\path", "C:\\Users\\张三\\bin\\sh.exe", "C:\\Users\\张三\\AppData\\Local\\x", "C:\\Users\\张三", "D:\\其他\\x", "c:\\users\\张三\\x", "C:\\Users\\张三x\\y"]) {
    let expected: unknown;
    try {
      expected = { ok: cmdPath(p, WIN_ENV) };
    } catch (e) {
      expected = { error: (e as Error).message };
    }
    await same({ fn: "cmdPath", path: p, env: WIN_ENV }, expected);
  }
  for (const real of ["C:\\Users\\a\\AppData\\Local\\Microsoft\\WinGet\\Packages\\OpenAI.Codex_Microsoft.Winget.Source_8wekyb3d8bbwe\\codex.exe", "C:/x/winget/packages/A_B/c", "C:\\x\\WinGet\\Packages\\Short_x\\y", "C:\\nothing", "C:\\WinGet\\Packages\\A_B_C_D\\"]) {
    await same({ fn: "wingetPackage", real }, wingetPackage(real));
  }
  for (const env of [WIN_ENV, { ...WIN_ENV, CLAUDE_CODE_GIT_BASH_PATH: "D:\\bash.exe" }, {}]) {
    for (const saved of [false, true]) {
      const dirs = w.pathOf(env).split(";");
      await same({ fn: "shellCandidates", env, dirs, saved }, w.shellCandidates(env, dirs, saved));
    }
    for (const there of [[], ["C:\\Program Files\\Git\\bin\\sh.exe", "C:\\Program Files\\Git\\cmd\\git.exe"], ["C:\\Tools\\sh.exe"], ["C:\\Program Files\\Git\\bin\\sh.exe"], ["D:\\bash.exe"]]) {
      await same({ fn: "gitShell", env, there }, gitShell(env, (p) => there.includes(p)));
      for (const saved of [null, ["E:\\Git\\cmd", "E:\\Git\\bin"]]) {
        const thereMore = [...there, "E:\\Git\\bin\\sh.exe", "E:\\Git\\cmd\\git.exe"];
        await same({ fn: "gitShellSoon", env, there: thereMore, saved }, await gitShellSoon(env, async () => saved, async (p) => thereMore.includes(p)));
      }
    }
  }
  const shims = [
    `@ECHO off\r\nGOTO start\r\n:find_dp0\r\nSET dp0=%~dp0\r\nEXIT /b\r\n:start\r\nSETLOCAL\r\nCALL :find_dp0\r\n\r\nIF EXIST "%dp0%\\node.exe" (\r\n  SET "_prog=%dp0%\\node.exe"\r\n) ELSE (\r\n  SET "_prog=node"\r\n  SET PATHEXT=%PATHEXT:;.JS;=;%\r\n)\r\n\r\nendLocal & goto #_undefined_# 2>NUL || title %COMSPEC% & "%_prog%"  "%dp0%\\node_modules\\@openai\\codex\\bin\\codex.js" %*\r\n`,
    `@"%~dp0\\node_modules\\@anthropic-ai\\claude-code\\bin\\claude.exe"   %*`,
    `@echo off\n"C:\\vp\\bin\\vp.exe" %*`,
    `@"%USERPROFILE%\\x.exe" %*`,
    `node "%~dp0\\cli.js" %*`,
    "nothing",
    `@echo off\r\nsetlocal\r\n"a.exe" %*\r\n"b.exe" %*`,
  ];
  for (const t of shims) {
    await same({ fn: "readShim", text: t }, readShim(t));
    await same({ fn: "shimOf", path: "C:\\npm\\codex.cmd", text: t }, w.shimOf("C:\\npm\\codex.cmd", t));
  }
  for (const [file, args, shim] of [["C:\\a b\\x.cmd", ["--flag", "v w"], null], ["C:\\x.cmd", ["50%"], null], ["x.cmd", ['say "hi"'], null], ["C:\\x.cmd", ["a"], { file: "node.exe", args: ["s.js"] }]] as const) {
    for (const env of [WIN_ENV, {}]) {
      let expected: unknown;
      try {
        expected = { ok: w.runnableOf(file, args, env, shim) };
      } catch (e) {
        expected = { error: (e as Error).message };
      }
      await same({ fn: "winRunnableOf", file, args, env, shim, comSpec: process.env.ComSpec }, expected);
    }
  }
  for (const env of [WIN_ENV, { programfiles: "C:\\PF" }, {}]) await same({ fn: "winBrowserPlaces", env }, w.browserPlaces(env));
  const cim = "100 4 1048576\r\n101 100 2048\r\n102 101 4096\r\n103 103 99\r\nx y z\r\n200 1 512\r\n101 100 4096\r\n";
  const gm = await winOf({ run: async () => ({ stdout: cim }) }, "groupMemory");
  await same({ fn: "winGroupMemory", text: cim, pgids: [100, 103, 300, 200] }, entries(await gm.groupMemory([100, 103, 300, 200])));
  const machine = { Path: "%SystemRoot%\\system32;%SystemRoot%;C:\\Program Files\\Git\\cmd;\\rooted;%NOPE%\\x", SystemRoot: "C:\\Windows" };
  const user = { PATH: "%USERPROFILE%\\bin;C:\\WINDOWS;relative;%LOCALAPPDATA%\\Programs\\agy", TEMP: "%USERPROFILE%\\t" };
  await same({ fn: "savedPathOf", machine, user, env: WIN_ENV }, savedPathOf(machine, user, WIN_ENV));
  await same({ fn: "savedPathOf", machine: {}, user: {}, env: {} }, savedPathOf({}, {}, {}));
  for (const env of [{ STILLFAIL_A: "it's", OTHER: "x", STILLFAIL_B: "y" }, {}] as Record<string, string>[]) await same({ fn: "windowsUpdateScript", runDir: "C:\\run's", env, task: "still.fail station update" }, windowsUpdateScript("C:\\run's", env, "still.fail station update"));
  for (const kept of [null, '{"task":"Mine","admin":true}', '  {"task":""}  ', "not json", '{"admin":1}']) {
    let script = "";
    const sm = await winOf({
      readFile: async () => { if (kept === null) throw new Error("none"); return kept; },
      rm: async () => {}, copyFile: async () => {}, writeFile: async () => {},
      spawn: (_: string, args: string[]) => { script = Buffer.from(args.at(-1)!, "base64").toString("utf16le"); return { on: (e: string, f: (c: number) => void) => e === "exit" && f(0) }; },
    }, `installer-${kept}`);
    await sm.startInstaller("C:\\s.ps1", "C:\\data\\run", {}, "C:\\app");
    const task = /-TaskName '([^']*)'/.exec(script)![1]!.replace(/''/g, "'");
    const admin = /-RunLevel (\w+)/.exec(script)![1] === "Highest";
    await same({ fn: "windowsTaskOf", kept }, { task, admin });
    await same({ fn: "windowsRegisterScript", hidden: "C:\\data\\run\\stillfail-update-w.exe", ps1: "C:\\data\\run\\update.ps1", runDir: "C:\\data\\run", task, admin }, script);
  }
  const there = ["C:\\", "E:\\", "Z:\\"];
  await same({ fn: "winDrives", there }, await w.drives(async (p: string) => there.includes(p)));
  for (const env of [WIN_ENV, { PATH: "a", path: "b" }, {}]) {
    await same({ fn: "winPrependPath", env, dir: "D:\\new", delim: win32.delimiter }, w.windows.prependPath(env, "D:\\new"));
    for (const dir of ["c:\\tools", "D:\\other"]) {
      const e: Record<string, string> = { ...(env as Record<string, string>) };
      w.windows.appendPath(e, dir);
      await same({ fn: "winAppendPath", env, dir, delim: win32.delimiter }, e);
    }
  }
  const cwd = process.cwd();
  for (const p of ["", "C:\\a\\b", "c:/A/b/../c", "C:", "\\x", "a:b", "C:\\", "relative\\x", "\\\\srv\\share\\x"]) {
    for (const d of ["C:\\a", "c:\\A\\", "C:\\", "D:\\"]) {
      await same({ fn: "winPaths", path: p, dir: d, cwd }, {
        clean: w.windows.paths.clean(p), key: w.windows.paths.key(p), within: w.windows.paths.within(p, d), isRootName: w.windows.paths.isRootName(p), rooted: w.windows.paths.rooted(p),
        join: w.windows.paths.join(d, p), relativeIn: w.windows.paths.relativeIn(d, p), isDrivePath: w.windows.paths.isDrivePath(p),
      }, `winPaths ${p} ${d}`);
    }
  }
  for (const env of [{}, { STILLFAIL_NATIVE_CACHE: "N" }, { LOCALAPPDATA: "L" }]) await same({ fn: "winNativeCache", env, home: "/h", join: "win32" }, w.windows.nativeCache(env, "/h"));
  for (const [path, shell, noop] of [["C:\\bin\\x", "C:\\Git\\bin\\sh.exe", false], ["C:/bin/y", null, true]] as const) {
    const name = path.slice(Math.max(path.lastIndexOf("\\"), path.lastIndexOf("/")) + 1);
    await same({ fn: "winCommandCmd", path, shell, noop }, noop ? "@exit /b 0\r\n" : `@"${shell}" "%~dp0${name}" %*\r\n`);
  }
  const netstat = "\r\nActive Connections\r\n\r\n  Proto  Local Address          Foreign Address        State           PID\r\n  TCP    127.0.0.1:8080         127.0.0.1:50000        ESTABLISHED     4242\r\n  TCP    127.0.0.1:50000        127.0.0.1:8080         ESTABLISHED     77\r\n  TCP    0.0.0.0:8080           0.0.0.0:0              LISTENING       4242\r\n  TCP    [::]:8080              [::]:0                 LISTENING       4242\r\n  TCP    [::1]:8080             [::]:0                 LISTENING       99\r\n  TCP    127.0.0.1:8080         127.0.0.1:50001        ESTABLISHED     4242\r\n  TCP    127.0.0.1:8080         127.0.0.1:50002        ESTABLISHED     x\r\n";
  for (const own of [4242, 1]) {
    const nm = await winOf({ run: async () => ({ stdout: netstat }), process: new Proxy(process, { get: (t, p) => (p === "pid" ? own : (t as any)[p]) }) }, `netstat-${own}`);
    await same({ fn: "netstatPortPids", text: netstat, port: 8080, own }, await nm.windows.tcpPortPids(8080));
    await same({ fn: "netstatListening", text: netstat, pids: [4242, 99], port: 8080 }, await nm.windows.listening([4242, 99], 8080));
  }
  for (const name of ["stillfail-station", "StillFail-Station-W\r\n", "node"]) {
    const lm = await winOf({ run: async () => ({ stdout: name }) }, `isl-${name}`);
    await same({ fn: "winIsLauncher", name }, await lm.windows.isLauncher(5));
  }
  for (const arch of ["arm64", "x64", "ia32"]) {
    for (const systemRoot of [undefined, "D:\\Win"]) {
      const nb = await winOf({
        process: new Proxy(process, { get: (t, p) => (p === "arch" ? arch : p === "env" ? { ...process.env, SystemRoot: systemRoot } : (t as any)[p]) }), join: win32.join,
      }, `nb-${arch}-${systemRoot}`);
      await same({ fn: "winNodeBuild", version: "24.1.0", arch, systemRoot }, nb.windows.nodeBuild("24.1.0"));
    }
  }
  for (const env of [{}, { LOCALAPPDATA: "C:\\L" }]) await same({ fn: "winAgyStaging", env, join: "win32" }, w.windows.agyStaging(env, "x"));
  for (const [onPath, real, there] of [
    ["C:\\Links\\codex.exe", "C:\\U\\AppData\\Local\\Microsoft\\WinGet\\Packages\\OpenAI.Codex_Microsoft.Winget.Source_8wekyb3d8bbwe\\codex.exe", []],
    ["C:\\vp\\codex.cmd", "C:\\vp\\codex.cmd", ["C:\\vp\\vp.exe"]],
    ["C:\\npm\\codex.cmd", "C:\\npm\\codex.cmd", ["C:\\npm\\node_modules\\@openai\\codex", "C:\\npm\\npm.cmd"]],
    ["C:\\npm\\codex.cmd", "C:\\npm\\codex.cmd", ["C:\\npm\\node_modules\\@openai\\codex"]],
    ["C:\\x\\codex.exe", "C:\\x\\codex.exe", []],
  ] as const) {
    const sm = await winOf({
      stat: async (p: string) => { if (!(there as readonly string[]).includes(p)) throw new Error("no"); return { isFile: () => true }; },
      join: win32.join, dirname: win32.dirname, findCommandSoon: async () => null,
    }, `shim-${onPath}-${there.join()}`);
    const winget = "C:\\winget.exe";
    const got = await sm.windows.shimUpdate({ onPath, real }, "@openai/codex", {});
    const expected = got !== null && typeof got === "object" && got.program?.endsWith("winget.exe") ? { ...got, program: winget } : got;
    await same({ fn: "winShimUpdate", onPath, real, pkg: "@openai/codex", winget, there, npm: null }, expected);
  }
  await same({ fn: "winInstalls" }, { claudeInstall: w.windows.claudeInstall, devinInstall: w.windows.devinInstall, agyInstall: w.windows.agyInstall });
});

// ── ops/: paths, version, own, unanswered, disk, nice, held, waits, group ──

test("ops/paths.ts and the small ones", { skip }, async () => {
  const wp = await privateOf("ops/paths.ts", { platform: (await winOf()).windows }, "win");
  const cwd = process.cwd();
  for (const path of ["", "/a/b/../c", "a//b/./", "C:\\x\\..\\y", "C:", "\\\\srv\\s", "..", "/", ".", "a\\b", "x/y/z.txt"]) {
    for (const dir of ["/a", "C:\\x", "", "/"]) {
      await same({ fn: "paths", platform: "unix", path, dir }, {
        segments: paths.segments(path), cleanPosix: paths.cleanPosix(path), clean: paths.clean(path), samePath: paths.samePath(path, dir), within: paths.within(path, dir), inside: paths.inside(path, dir),
        fileName: paths.fileName(path), anyBaseName: paths.anyBaseName(path), joinPath: paths.joinPath(dir, path), relativeParts: paths.relativeParts(path),
      }, `paths unix ${path} ${dir}`);
      await same({ fn: "paths", platform: "windows", cwd, path, dir }, {
        segments: wp.segments(path), cleanPosix: wp.cleanPosix(path), clean: wp.clean(path), samePath: wp.samePath(path, dir), within: wp.within(path, dir), inside: wp.inside(path, dir),
        fileName: wp.fileName(path), anyBaseName: wp.anyBaseName(path), joinPath: wp.joinPath(dir, path), relativeParts: wp.relativeParts(path),
      }, `paths windows ${path} ${dir}`);
    }
  }
  for (const name of ["ok.txt", "", ".hidden", "a:b", "x.", "x ", "CON", "con.txt", "COM1", "lpt²", "console", "名字", "a".repeat(300), "a/b", "tab\there", "LPT9.x.y"]) {
    await same({ fn: "portable", name }, { name: paths.portableName(name), component: paths.portableComponent(name) });
  }
  for (const build of [null, "1234\n", "", "12a", " 7 "]) await same({ fn: "stationVersion", build }, stationVersion(build === null ? "/nonexistent-dir" : (() => { const d = fresh("build"); writeFileSync(join(d, "BUILD"), build); return d; })()));
  const o = new Own("/data", "/data/config.json");
  o.add(() => ["/a"]);
  o.add(() => ["/b", "/c"]);
  await same({ fn: "own", data: "/data", config: "/data/config.json", more: [["/a"], ["/b", "/c"]] }, { more: o.more(), paths: o.paths() });
  const errs: [unknown, Record<string, unknown>][] = [
    [Object.assign(new Error("x"), { name: "TimeoutError" }), { isError: true, name: "TimeoutError", message: "x" }],
    [new TypeError("fetch failed"), { isError: true, typeError: true, name: "TypeError", message: "fetch failed" }],
    [Object.assign(new Error("y"), { code: "ECONNRESET" }), { isError: true, name: "Error", message: "y", code: "ECONNRESET" }],
    [Object.assign(new Error("y"), { code: "EACCES" }), { isError: true, name: "Error", message: "y", code: "EACCES" }],
    ["string", { isError: false }],
  ];
  for (const [e, c] of errs) await same({ fn: "unanswered", ...c }, unanswered(e));
  const G = 1024 ** 3;
  for (const [free, total] of [[10 * G, 100 * G], [25 * G, 100 * G], [25 * G, 1000 * G], [40 * G, 100 * G], [200 * G, 1000 * G]]) {
    await same({ fn: "disk", free, total }, { soft: diskSoft(total), tier: diskTier(free, total), every: diskEvery(diskTier(free, total)) });
  }
  for (const given of [undefined, "0", "19", "20", "-1", "5.5", "abc", "", " 7 "]) {
    const nm = await privateOf("ops/nice.ts", { process: { env: given === undefined ? {} : { STILLFAIL_AGENT_NICE: given } } }, `nice-${given}`);
    await same({ fn: "agentNice", given }, nm.agentNice());
  }
  const data = fresh("held");
  mkdirSync(join(data, "run"));
  for (const [station, hub, alive] of [['{"pid": 10}', '{"pid": 20}', [10, 20]], ['{"pid": 10}', '{"pid": 20}', [20]], ["bad", '{"pid": 1.5}', [1]], [null, '{"pid": 999}', [999]], ['{"pid": 50}', null, []]] as const) {
    for (const [name, t] of [["station.json", station], ["hub.json", hub]] as const) {
      if (t === null) rmSync(join(data, "run", name), { force: true });
      else writeFileSync(join(data, "run", name), t);
    }
    await same({ fn: "heldBy", texts: [station, hub], self: 50, alive }, heldBy(data, 50, (p) => (alive as readonly number[]).includes(p)));
  }
  const w = noWaits();
  const ws = [{ ms: 5, who: "a" }, { ms: 25, who: "readFileSync x < y" }, { ms: 40.6, who: "statSync z" }, { ms: 20, who: "readFileSync x < y" }, { ms: 19.9, who: "never" }];
  for (const x of ws) waited(w, x.ms, () => x.who);
  for (const most of [3, 1]) await same({ fn: "waits", waits: ws, most }, { waits: { ms: w.ms, calls: w.calls, longest: w.longest, by: [...w.by].map(([k, v]) => [k, v.ms, v.calls]) }, longest: longestWaits(w, most) });
  const stacks = [
    "Error\n    at timed (file.js:1:1)\n    at time2 (x)\n    at Store.#one (s.js:1)\n    at async readThreads (r.js:2:3)\n    at <anonymous> (z)\n    at Hub.take (h.js:1)\n    at main (m.js:1)\n    at more (m.js:2)",
    "Error\n    at Object.<anonymous> (a)\n    at file:///x.js:1:2\n    at async Promise.all (index 0)",
    undefined,
    "Error\n  at async  (x)\n    at async (y)",
  ];
  for (const stack of stacks) await same({ fn: "askedBy", stack }, askedBy(stack));
  const gm = await privateOf("ops/group.ts", {}, "group");
  for (const [started, startedAt, outlives, alive] of [[1000, 3000, true, true], [1000, 9000, true, true], [null, 1, true, true], [null, 1, false, true], [1000, 1000, true, false]] as const) {
    const g = await privateOf("ops/group.ts", { platform: { groupOutlivesLeader: outlives, groupAlive: () => alive, startTimeOf: async () => started } }, `g-${started}-${outlives}-${alive}`);
    await same({ fn: "stillOurs", started, startedAt, outlives, alive }, await g.stillOurs({ pgid: 1, startedAt } as never));
  }
  void gm;
  for (const grace of [0, 50, 100, 250, 5000]) await same({ fn: "endGroupLooks", grace }, Math.max(1, Math.floor(grace / 100)));
});

// ── ops/i18n.ts, model-name.ts, agent-env.ts ──

const ZH = JSON.parse(readFileSync(join(ROOT, "client/i18n/catalog/zh/station.json"), "utf8"));
const EN = JSON.parse(readFileSync(join(ROOT, "client/i18n/catalog/en/station.json"), "utf8"));

test("ops/i18n.ts, model-name.ts and agent-env.ts", { skip }, async () => {
  await mb({ fn: "catalog", zh: ZH, en: EN });
  for (const locale of [undefined, "", "zh-CN", "ZH", "en-US", " fr ", "zhx"]) await same({ fn: "langOf", locale }, langOf(locale));
  for (const origin of ["https://app.still.fail", "https://app.monoid.build", "monoid.zone", "https://x.monoid.zone/", "notaurl", "https://monoid.build.evil.com"]) {
    await same({ fn: "productOf", origin }, productOf(origin).name);
    for (const t of ["Welcome to still.fail", "app.still.fail and still.fail.", "still.fails x@still.fail /still.fail", "(still.fail)", "still.fail-x still.fail.app still.fail."]) {
      await same({ fn: "branded", text: t, origin }, branded(t, productOf(origin)));
    }
  }
  const keys = Object.keys(ZH).slice(0, 400).concat(["no.such.key", "station.place.timeout", "station.files.invalidJson"]);
  const args = { cwd: "/x", seconds: 5, machine: "m", n: 1, path: "/p", program: "still.fail", count: 3 };
  for (const lang of ["zh", "en"] as const) {
    for (const key of keys) await same({ fn: "tr", lang, key, args }, tr(lang, key, args), `tr ${lang} ${key}`);
  }
  for (const key of Object.keys(ZH).filter((k) => typeof ZH[k] === "object").slice(0, 20)) {
    for (const n of [1, 2, "1", " 1"]) await same({ fn: "tr", lang: "en", key, args: { n } }, tr("en", key, { n }), `plural ${key} ${n}`);
  }
  const ids = [
    "claude-opus-5-5", "claude-sonnet-4-5-20250929", "opus", "claude-fable-5-2[1m]", "anthropic/claude-haiku-4-5", "gpt-6-astra", "gpt-6.1-sol", "o4-mini", "o3", "gpt-oss-120b",
    "deepseek-v4-pro", "qwen3-coder-480b", "glm-4.6", "gemini-4-carbon", "gemini-4-hydrogen-high", "kimi-k2", "grok-code-fast-1", "swe-1.5", "adaptive", "mystery-model", " Spaced ",
    "fusion-claude-opus-5-5-high-sidekick-gpt-6-sol-low", "fusion-x-sidekick-", "llama-3.1-70b", "codex-mini", "minimax-m2", "devstral-small-2505", "claude", "o1x", "qwq-32b",
  ];
  for (const id of ids) {
    await same({ fn: "modelName", id }, modelName(id), `modelName ${id}`);
    await same({ fn: "makerOf", model: id }, makerOf(id), `makerOf ${id}`);
  }
  const raws = [{ agentEnv: { HTTPS_PROXY: "http://p", "BAD NAME": "x", n: 1, _ok: "y" } }, null, { agentEnv: [] }, "x", { agentEnv: { A1: "" } }];
  for (const raw of raws) await same({ fn: "agentEnv", raw }, agentEnv(raw));
  const sets = [undefined, null, [], "x", { A: "b" }, { "1A": "x" }, { A: 1 }, { A: "line\nbreak" }, { A: "x".repeat(4097) }, Object.fromEntries(Array.from({ length: 65 }, (_, i) => [`V${i}`, "x"]))];
  for (const set of sets) {
    let expected: string | null = null;
    try {
      checkAgentEnv(set);
    } catch (e) {
      expected = (e as Error).message;
    }
    await same({ fn: "checkAgentEnv", ...(set === undefined ? {} : { set }) }, expected);
  }
  const kept = { API_KEY: "sk-1234567890abcdef", PLAIN: "visible" };
  for (const t of [
    "A=1\nexport B = 'two'\n# c\n\nC=\"x\"\nexport\tD=4", "noequals", "=x", "1BAD=x", `L=${"x".repeat(4097)}`, `API_KEY=${maskValue(kept.API_KEY)}\nPLAIN=••••`, "A=1\r\nA=2",
    Array.from({ length: 65 }, (_, i) => `V${i}=x`).join("\n"), "exportX=1", "A='mismatch\"",
  ]) await same({ fn: "parseEnvText", text: t, kept }, parseEnvText(t, kept), `parseEnvText ${t.slice(0, 30)}`);
  for (const v of ["", "short", "12345678", "123456789", "密码密码密码密码密码", "😀😀😀😀😀😀😀😀😀😀"]) await same({ fn: "maskValue", value: v }, maskValue(v));
  for (const [k, v] of [["api_key", "x"], ["PATH", "/bin"], ["HTTP_PROXY", "http://u:p@proxy:8080"], ["X", "http://proxy:8080"], ["X", "socks5h://u:@h"], ["X", "1http://u:p@h"], ["X", "http://a/b:c@d"]]) {
    await same({ fn: "secretValue", key: k, value: v }, secretValue(k!, v!));
  }
  for (const env of [{ PATH: "/bin" }, { HTTPS_PROXY: "http://p" }, { https_proxy: "http://p", NO_PROXY: "a.com, localhost" }, { ALL_PROXY: "x", no_proxy: "*" }, { HTTP_PROXY: "", http_proxy: "y" }] as Record<string, string>[]) {
    await same({ fn: "keepLocal", env }, keepLocal(env));
    const am = await privateOf("ops/agent-env.ts", {}, "agentEnvPrivate");
    const agentsSeen: Record<string, string>[] = [];
    const fakeHttps = { Agent: class { constructor(o: { proxyEnv: Record<string, string> }) { agentsSeen.push(o.proxyEnv); } destroy() {} } };
    const pm = await privateOf("ops/agent-env.ts", { https: fakeHttps }, `proxy-${JSON.stringify(env)}`);
    void am;
    const agent = pm.proxyAgent(env);
    await same({ fn: "proxyEnv", env }, agent === null ? null : agentsSeen.at(-1));
  }
  for (const [own, raw, scrubbed] of [[{ PATH: "/bin", SECRET: "s" }, { agentEnv: { HTTPS_PROXY: "http://p", PATH: "/over" } }, ["SECRET"]], [{ A: "1" }, null, []]] as const) {
    const sm = await privateOf("ops/agent-env.ts", { process: { env: own } }, `startEnv-${JSON.stringify(own)}`);
    sm.readAgentEnvFrom(() => raw);
    await same({ fn: "startEnv", env: own, raw, scrubbed }, sm.startEnv([...scrubbed]));
  }
});

// ── ops/launcher.ts, restart.ts, previous.ts, health.ts, files.ts, log.ts ──

test("ops/launcher.ts: the control channel's lines both ways", { skip }, async () => {
  const argvs = [
    [], ["--launcher-fds", "3,4,5"], ["--launcher-fds", "3,4,5", "--launcher-carries", "--launcher-heartbeat"], ["--launcher-fds", "3,4"], ["--launcher-fds", "3,x,5"],
    ["--launcher-pipe", "\\\\.\\pipe\\x", "--launcher-ports", "4750,4760", "--launcher-heartbeat", "--launcher-carries"], ["--launcher-pipe", "p", "--launcher-ports", "1,0"], ["--launcher-fds", "3,4,5,6", "--launcher-ports", "1,2"],
  ];
  const said = [
    { op: "ready", version: "0.1.9" }, { op: "serving", name: "mcp", port: 4750 }, { op: "taking" }, { op: "failed", why: "the agents' side did not start: \"x\"\n" }, { op: "drained", how: "idle" },
    { op: "carry", what: { a: [1, "é\u2028"], b: null } }, { op: "heartbeat" }, { op: "restartFront" },
  ];
  for (const args of argvs) {
    const written: string[] = [];
    const sockets: { on: (e: string, f: (x?: unknown) => void) => void }[] = [];
    const fakeSocket = function () {
      const s = { on: () => {}, write: (t: string) => { written.push(t); return true; } };
      sockets.push(s);
      return s;
    };
    const lm = await privateOf("ops/launcher.ts", {
      Socket: fakeSocket, createConnection: fakeSocket, process: { on: () => {} }, log: { warn: () => {} },
    }, `launcher-${args.join(" ")}`);
    const control = lm.launcher(args);
    await same({ fn: "launcherArgs", args }, {
      linked: written !== null && (control.ports !== undefined || control.mcpFd !== undefined || sockets.length > 0),
      ...(control.mcpFd !== undefined ? { mcpFd: control.mcpFd, loopbackFd: control.loopbackFd } : {}),
      ...(control.ports !== undefined ? { ports: control.ports } : {}),
      carries: control.carries, restartFront: control.restartFront !== undefined,
    }, `launcherArgs ${args.join(" ")}`);
    for (const s of said) {
      if (s.op === "ready") control.ready(s.version);
      else if (s.op === "serving") control.serving(s.name, s.port);
      else if (s.op === "taking") control.taking();
      else if (s.op === "failed") control.failed(s.why);
      else if (s.op === "drained") control.drained(s.how);
      else if (s.op === "carry") control.carry(s.what);
      else if (s.op === "heartbeat") control.heartbeat();
      else control.restartFront?.();
    }
    const lines = await mb({ fn: "launcherSaid", args, said });
    assert.deepEqual(lines.filter((l: string | null) => l !== null), written, `said ${args.join(" ")}`);
  }
  // What it is told: lines in pieces, empty lines, what is carried before and after it is taken.
  const told = ['{"op":"handover"}\n{"op":"car', 'ried","carried":{"k":"v"}}\n\n', 'not json\n{"op":"stop"}\n', 'null\n5\n{"op":7}\n{"op":"carried"}\n{"op":"drain"}', "\n{\"op\":\"hup\"}\n{\"partial"];
  for (const takeAt of [0, 2, 5]) {
    let onData: ((c: Buffer) => void) | null = null;
    const warned: number[] = [];
    const fakeSocket = function () {
      return { on: (e: string, f: (c: Buffer) => void) => { if (e === "data") onData = f; }, write: () => true };
    };
    const lm = await privateOf("ops/launcher.ts", { Socket: fakeSocket, createConnection: fakeSocket, process: { on: () => {} }, log: { warn: (_a: string, _b: string, f: { length: number }) => warned.push(f.length) } }, `told-${takeAt}`);
    const control = lm.launcher(["--launcher-fds", "3,4,5"]);
    const ops: unknown[] = [];
    for (const op of ["handover", "stop", "drain", "hup", "7"]) control.on(op, () => ops.push({ op }));
    const taken: unknown[] = [];
    for (let i = 0; i < told.length; i++) {
      if (i === takeAt) control.carried((w: unknown) => taken.push(w));
      onData!(Buffer.from(told[i]!));
    }
    if (takeAt >= told.length) control.carried((w: unknown) => taken.push(w));
    const got = await mb({ fn: "launcherTold", chunks: told, takeAt });
    const heard = got.told.filter((t: any) => "op" in t && ["handover", "stop", "drain", "hup", "7"].includes(t.op));
    assert.deepEqual(heard, ops, `told ops ${takeAt}`);
    assert.deepEqual(got.told.filter((t: any) => "unreadable" in t).map((t: any) => t.unreadable), warned, `told unreadable ${takeAt}`);
    assert.deepEqual(got.taken, plain(taken), `told carried ${takeAt}`);
  }
});

test("ops/restart.ts, previous.ts, health.ts, files.ts, log.ts", { skip }, async () => {
  for (const [text, launchers] of [[null, [1]], ['{"pid":42,"handoff":1}', [42]], ['{"pid":42,"handoff":1}', []], ['{"pid":42,"handoff":2}', [42]], ['{"pid":-1,"handoff":1}', [-1]], ["nope", []], ['{"pid":4.2,"handoff":1}', [4.2]]] as const) {
    const rm = await privateOf("ops/restart.ts", {
      readFile: async () => { if (text === null) throw new Error("none"); return text; },
      platform: { isLauncher: async (p: number) => (launchers as readonly number[]).includes(p), askLauncher: async () => {} },
    }, `restart-${text}-${launchers.join()}`);
    const r = await rm.restarter("/d");
    await same({ fn: "restarterPid", text, launchers }, r === null ? null : JSON.parse(text!).pid);
  }
  const { pageRestart } = await import("../src/ops/restart.ts");
  for (const handover of [false, true]) for (const front of [false, true]) {
    const ran: string[] = [];
    const page = pageRestart("/d", front ? () => ran.push("front") : undefined, { find: async () => (handover ? async () => void ran.push("handover") : null), later: (_ms, f) => f() });
    const got = await page();
    const kind = got === null ? "none" : (await got(), ran.includes("front") ? "front" : "handover");
    await same({ fn: "pageRestart", handover, restartFront: front }, kind);
  }
  for (const [t, self] of [[null, 1], ['{"pid":7}', 1], ['{"pid":7}', 7], ['{"pid":"7"}', 1], ["[]", 1], ["null", 1]] as const) {
    const pm = await privateOf("ops/previous.ts", { readFileSync: () => { if (t === null) throw new Error("none"); return t; }, process: { pid: self, kill: () => { throw Object.assign(new Error(), { code: "ESRCH" }); } } }, `prev-${t}-${self}`);
    await same({ fn: "previousPid", text: t, self }, pm.previousProcess("/run").pid);
  }
  const hs = [{ pid: 1, updatedAt: 5, front: "ok" }, { pid: 1.5, updatedAt: 5, front: "ok" }, { pid: 1, updatedAt: "5", front: "ok" }, { pid: 1, updatedAt: 5, front: "nope" }, null, "x",
    { pid: 2, updatedAt: 9, front: "reconnecting", heldMaxMs: 77, presenceOnline: true, relayConflict: true, extra: 1 }, { pid: 3, updatedAt: 9, front: "direct", presenceOnline: "yes", relayConflict: false }];
  for (const h of hs) await same({ fn: "healthOf", h }, healthOf(h));
  for (const running of [false, true]) for (const health of [null, hs[0], hs[6], { pid: 1, updatedAt: -100000, front: "ok" }]) for (const healthAlive of [false, true]) for (const online of [false, true]) for (const conflict of [false, true]) {
    const h = health === null ? null : healthOf(health);
    await same({ fn: "workingOf", running, health, healthAlive, online, conflict, now: 1000 }, workingOf({ running, health: h, healthAlive, online, conflict, now: 1000 }));
  }
  const hm = await privateOf("ops/health.ts", { writeFile: async (_: string, t: string) => void (written = t), rename: async () => {} }, "writeHealth");
  let written = "";
  const health = { pid: 9, updatedAt: 1.5, heldMaxMs: 0, front: "ok", presenceOnline: false };
  await hm.writeHealth("/d", health);
  await same({ fn: "healthText", health }, written);
  const fm = await privateOf("ops/files.ts", {}, "files");
  for (const [args, envData, home] of [[["--data", "/d"], undefined, "/h"], [["--data"], "/e", "/h"], [[], "", "/h"], [["--data", ""], undefined, "/h2"]] as const) {
    const dm = await privateOf("ops/files.ts", { process: { env: envData === undefined ? {} : { STILLFAIL_DATA: envData } }, homedir: () => home }, `data-${JSON.stringify([args, envData, home])}`);
    await same({ fn: "dataDir", args, envData, home }, dm.dataDir([...args]));
  }
  for (const [data, home] of [["/h/.stillfail", "/h"], ["/h/.stillfail/", "/h"], ["/h/./.stillfail", "/h"], ["/other", "/h"]]) await same({ fn: "ownData", platform: "unix", data, home }, fm.ownData(data, home));
  for (const t of [null, '{"port": 4750}', '{"port": 0}', '{"port": 70000}', '{"port": "1"}', "x"]) {
    const rm = await privateOf("ops/files.ts", { readFileSync: () => { if (t === null) throw new Error("none"); return t; } }, `mcp-${t}`);
    await same({ fn: "rememberedMcpPort", text: t }, rm.rememberedMcpPort("/d") ?? null);
  }
  for (const [named, remembered, usual, own] of [[undefined, undefined, 4750, true], [5000, 1, 2, true], [undefined, 4750, 4750, true], [undefined, 1234, 4750, false], [undefined, 0, 4750, true]] as const) {
    await same({ fn: "portsToTry", named, remembered, usual, own }, portsToTry(named, remembered, usual, own));
  }
  for (const args of [["run", "--data", "/d", "x"], ["enroll", "--token", "-abc", "--", "--x", "y"], ["a", "--Bad", "--x-y-z", "-v", "--" + "a".repeat(30)], []]) {
    await same({ fn: "positionals", args, valued: ["--data", "--token"] }, positionals(args, ["--data", "--token"]));
    await same({ fn: "flag", args, name: "--data" }, flag(args, "--data") ?? null);
  }
  for (const lang of ["zh", "en"] as const) for (const folderPermissions of [false, true]) for (const argv of [["node", "main.js"], ["node", "main.js", "--app", "/Apps/x"], ["--app", "/A", "--with-parent"]]) {
    const um = await privateOf("ops/files.ts", { platform: { hasFolderPermissions: folderPermissions, paths: { key: (p: string) => p, clean: (p: string) => p } } }, `unread-${folderPermissions}`);
    await same({ fn: "unreadableDirMessage", lang, dir: "/Users/x/Documents", argv, folderPermissions }, um.unreadableDirMessage(lang, "/Users/x/Documents", argv));
  }
  const { InvalidJsonFile } = await privateOf("ops/json-file.ts", { process: { execPath: "/node" } }, "json");
  for (const lang of ["zh"]) await same({ fn: "invalidJsonMessage", lang, path: "/c.json", program: "/node" }, new InvalidJsonFile("/c.json").message);
  for (const ms of [0, 1_790_000_123_456, 951_782_400_000, -1, 253_402_300_799_999, 1.7]) await same({ fn: "isoTime", ms }, new Date(ms).toISOString());
  const lines: string[] = [];
  const lm = await privateOf("ops/log.ts", { wall: { now: () => 1_790_000_000_000 }, process: { stderr: { write: (t: string) => lines.push(t) } } }, "log");
  for (const fields of [undefined, { a: "x", b: 1, c: { d: [true] }, e: null }, {}]) {
    lm.log.warn("here", "something", fields);
    await same({ fn: "logLine", now: 1_790_000_000_000, level: "WARN", at: "here", message: "something", fields }, lines.at(-1));
    let heard: unknown[] = [];
    lm.hearErrors((log: string, error: string | null) => (heard = [log, error]));
    lm.log.error("x", "boom", fields === undefined ? undefined : { ...fields, error: "the error" });
    await same({ fn: "errorHeard", message: "boom", fields: fields === undefined ? undefined : { ...fields, error: "the error" } }, heard);
  }
});

// ── ops/command-output.ts and loopback.ts ──

const OUTPUTS = [
  "\u001b[1;32m✓\u001b[0m Logged in as \u001b]0;title\u0007me\r\nnext\r\r\nline\rover\bx\u000e\u000fy\u001b]8;;https://x\u001b\\link\u001b(B",
  "! First copy your one-time code: ABCD-1234\nPress Enter to open github.com in your browser...",
  "To sign in, use a web browser to open the page https://microsoft.com/devicelogin and enter the code GQGFJ2QXM to authenticate.",
  "Visit https://dash.cloudflare.com/oauth2/auth?response_type=code&client_id=x&redirect_uri=http%3A%2F%2Flocalhost%3A8976%2Foauth%2Fcallback&state=abc&code_challenge=XYZ123456789",
  "Your code:\n\nvFA9uVPF\nthen",
  "code is ABC12345 thanks",
  "Enter code: lowercase",
  "The code XYZ was (https://a.example/path).",
  "https://login.example/device?user_code=WXYZ-9876 and https://x.y/z.",
  "Open https://vercel.com/oauth/device?user_code=AbCd-EfGh...",
  "Authentication complete. Press Enter to continue",
  "✓ Successfully authenticated to github.com",
  "nothing here at all",
  "https://a.b/c, https://d.e/f) and (https://g.h/(i)) https://...",
  "your verification code=AB12CD34 ok",
  "a code — 12345678 — b",
  "codeword ABCDEF1",
  "user_code=ABCD-12345678x ?user_code=ABCD-123&",
];

test("ops/command-output.ts and loopback.ts", { skip }, async () => {
  for (const t of OUTPUTS) {
    await same({ fn: "plainText", text: t }, out.plainText(t));
    await same({ fn: "urlsIn", text: t }, out.urlsIn(t));
    await same({ fn: "deviceCodeIn", said: t, opened: [] }, out.deviceCodeIn(t), `deviceCodeIn ${t.slice(0, 40)}`);
    for (const line of t.split("\n")) {
      await same({ fn: "asksEnter", line }, out.asksEnter(line), `asksEnter ${line}`);
      await same({ fn: "prompts", line }, out.prompts(line), `prompts ${line}`);
      await same({ fn: "secretAsked", line }, out.secretAsked(line));
    }
    await same({ fn: "saysDone", text: t }, out.saysDone(t), `saysDone ${t.slice(0, 40)}`);
  }
  await same({ fn: "deviceCodeIn", said: "", opened: ["https://x/?user_code=Q1W2-E3R4"] }, out.deviceCodeIn("", ["https://x/?user_code=Q1W2-E3R4"]));
  const wide = `Open this:\n${"x".repeat(60)} https://example.com/${"a".repeat(30)}\n${"b".repeat(40)}&c=d\nend`;
  for (const cols of [80, 100, 200]) await same({ fn: "unwrapped", text: wide, cols }, out.unwrapped(wide, cols));
  const urls = [
    "https://github.com/login/oauth/authorize?client_id=x&redirect_uri=http://127.0.0.1:43210/callback&state=s1",
    "https://login.microsoftonline.com/x?redirect_uri=http%3A%2F%2Flocalhost%3A8400&response_mode=form_post",
    "https://accounts.example/signin?continue=https%3A%2F%2Fauth.example%2Fo%3Fredirect_uri%3Dhttp%3A%2F%2F%5B%3A%3A1%5D%3A9000%2Fcb%26state%3Dinner&state=outer",
    "https://x/?callback=http://localhost/no-port", "https://x/?Redirect_URI=http://127.0.0.1:0/", "https://x/?redirect=https://localhost:1/", "not a url", "https://x/?return_to=http://localhost:65536/",
    "https://device.example/activate", "https://example.com/verify?user_code=1",
  ];
  for (const u of urls) {
    await same({ fn: "loopbackOf", url: u }, out.loopbackOf(u), `loopbackOf ${u}`);
    await same({ fn: "domainOf", url: u }, out.domainOf(u));
  }
  for (const code of ["1", "ABCD"]) await same({ fn: "deviceUrls", urls, code }, out.deviceUrls(urls, code));
  for (const name of ["/usr/bin/git-credential-osxkeychain", "pinentry-mac", "node", "C:\\x\\askpass.exe"]) await same({ fn: "storesSecret", name }, out.storesSecret(name));
  for (const words of [["A=1", "HOME_X=~/x", "B=~", "C=~user", "gh", "auth"], ["gh"], [], ["1A=x", "y"]]) {
    for (const home of [undefined, "/h"]) {
      const a = out.assignmentsOf(words, home);
      await same({ fn: "assignmentsOf", words, home }, { env: a.env, rest: a.rest });
    }
  }
  for (const words of [["env", "-u", "X", "A=1", "sudo", "-u", "me", "npx", "-p", "pkg", "vercel@latest", "login"], ["/x/bin/devin", "auth"], ["pnpm", "dlx", "wrangler@3", "login"], ["npm", "exec", "--", "@scope/x@1"], [], ["A=1"], ["uvx", "--from", "x", "tool"], ["@scope/pkg"]]) {
    await same({ fn: "programOf", words }, out.programOf(words), `programOf ${words.join(" ")}`);
  }
  for (const line of [`vercel login --scope "my team"`, "a\\ b 'c d' \"e\\\"f\\$g\\h\"", "unclosed 'x", "  spaced   out  ", "''", "x\"\"y"]) await same({ fn: "commandWords", line }, out.commandWords(line));
  for (const url of [undefined, "HTTPS://x", "ftp://x", "http:/x"]) await same({ fn: "webPage", url }, out.webPage(url));
  for (const [said, accept] of [[undefined, "en-US,en;q=0.9"], ["zh", "en"], [undefined, "*"], [undefined, undefined], [undefined, "fr;q=1"]]) {
    const headers: Record<string, string> = {};
    if (said !== undefined) headers["stillfail-lang"] = said;
    if (accept !== undefined) headers["accept-language"] = accept;
    await same({ fn: "langOfBrowser", said, accept }, langOfBrowser(headers));
  }
  const place = { origin: "https://app.still.fail//", workspace: "W", workspace_name: "Team", station: "S" };
  for (const path of ["/", "/admin", "/chats/1", "/services/x", "/bots/b", "/settings/accounts", "/settings/accounts/a", "/settings/memory", "/settings/device", "/settings", "/new", "/archive", "/x/y/z"]) {
    for (const query of [null, "", "a=1"]) await same({ fn: "moved", path, query, ...place }, moved(path, query, place));
  }
  for (const path of ["/healthz", "/admin/api/x", "/admin/api", "/other", "/", "/admin/chats/1"]) {
    for (const p of [null, place, { ...place, removed_at: 1_790_000_000 }, { ...place, workspace: "" }]) {
      for (const lang of ["zh", "en"] as const) {
        await same({ fn: "loopbackAnswer", path, query: "q=1", ready: path === "/healthz" && p !== null, place: p, lang }, loopbackAnswer(path, "q=1", path === "/healthz" && p !== null, p, lang));
      }
    }
  }
});


// ── ops/walk.ts, follow.ts, storage.ts, config.ts on files of the test's own ──

/// A tree to walk: folders, files, a link to a folder (one back up too), a link to nothing.
function tree() {
  const root = fresh("tree");
  for (const d of ["a/b/c", "a/d", "e", "f/g/h/i"]) mkdirSync(join(root, d), { recursive: true });
  for (const [f, size] of [["a/one.txt", 10], ["a/b/two.txt", 2000], ["a/b/c/three", 0], ["e/four", 5], ["zz", 7]] as const) writeFileSync(join(root, f), "x".repeat(size));
  symlinkSync(join(root, "a"), join(root, "e", "to-a"));
  symlinkSync("..", join(root, "a", "d", "up"));
  symlinkSync(join(root, "nowhere"), join(root, "dangling"));
  return root;
}

test("ops/walk.ts and follow.ts on a tree of files", { skip }, async () => {
  const { walkBounded } = await import("../src/ops/walk.ts");
  const root = tree();
  const link = join(fresh("rootlink"), "l");
  symlinkSync(root, link);
  const cases: Record<string, unknown>[] = [
    {}, { maxEntries: 5 }, { maxDepth: 1 }, { maxDepth: 2 }, { followLinks: true }, { stat: true }, { skip: [`${root}:a`] }, { stop: [`${root}:a/b`] },
    { roots: [root, join(root, "e"), join(root, "missing")] }, { roots: [link] }, { roots: [link], followRoot: true }, { followLinks: true, maxDepth: 3 }, { sameDevice: false, stat: true },
  ];
  for (const c of cases) {
    const roots = (c.roots as string[] | undefined) ?? [root];
    const visited: unknown[] = [];
    const errors: unknown[] = [];
    const crossed: unknown[] = [];
    const skips = (c.skip as string[] | undefined) ?? [];
    const stops = (c.stop as string[] | undefined) ?? [];
    const result = await walkBounded(roots, (e) => {
      visited.push({ path: e.path, rel: e.rel, name: e.name, depth: e.depth, directory: e.directory, symlink: e.symlink, file: e.file, size: e.stats === null ? null : Number(e.stats.size), root: e.root });
      const key = `${e.root}:${e.rel}`;
      return stops.includes(key) ? "stop" : skips.includes(key) ? "skip" : undefined;
    }, {
      maxEntries: c.maxEntries as number | undefined, maxDepth: c.maxDepth as number | undefined, stat: c.stat as boolean | undefined, followRoot: c.followRoot as boolean | undefined,
      followLinks: c.followLinks as boolean | undefined, sameDevice: c.sameDevice as boolean | undefined, now: () => 0,
      onError: (p, _e, op) => errors.push([p, op]), onCrossed: (e) => crossed.push(e.path),
    });
    await same({ fn: "walk", roots, ...c }, { result, visited, errors, crossed }, `walk ${JSON.stringify(c)}`);
  }
  // A followed tree: what is let in watched, a watch that fails, more than `most`.
  const { FollowedTree } = await import("../src/ops/follow.ts");
  for (const [into, most, failing] of [
    [["a", "a/b", "e", "f"], 100, {}], [["a", "a/b", "a/b/c", "f", "f/g"], 3, {}], [["a", "e"], 100, { [join(root, "e")]: "EMFILE" }], [["a", "e"], 100, { [join(root, "a")]: "ENOENT" }], [[], 1, {}],
  ] as const) {
    const watch = (dir: string) => {
      const code = (failing as Record<string, string>)[dir];
      if (code !== undefined) throw Object.assign(new Error(code), { code });
      return { close() {}, on() {} };
    };
    const t = new FollowedTree({ root, into: (rel) => (into as readonly string[]).includes(rel), changed: () => {}, most, watch });
    const scans: unknown[] = [];
    for (let i = 0; i < 2; i++) {
      const r = await t.scan();
      scans.push({ failed: r.failed === undefined ? null : (r.failed as NodeJS.ErrnoException).code, over: r.over === true, watched: t.watched() });
    }
    await same({ fn: "follow", root, into, most, failing, scans: 2 }, scans, `follow ${JSON.stringify([into, most, failing])}`);
  }
  for (const [rel, name] of [["", "x"], ["a", "y"], ["a/b", null], ["", null]] as const) await same({ fn: "followedChange", rel, name }, name === null ? rel : rel === "" ? name : `${rel}/${name}`);
});

test("ops/storage.ts: the manifest and the upkeep", { skip }, async () => {
  const st = await import("../src/ops/storage.ts");
  await same({ fn: "storageManifest" }, st.STORAGE_MANIFEST);
  for (const name of ["stillfail.db", "config.json.bak-123", "config.json.bak-", "comma-stats.db-wal", "nope", "config.jsonxbak-1", "Trash", "config.json.bak-a\nb"]) await same({ fn: "storageEntry", name }, st.storageEntry(name) ?? null);
  for (const [size, cap, keep] of [[10, 20, 20], [30, 20, 20], [30, 20, 50], [64, 64, 1]]) await same({ fn: "rotatePlan", size, cap, keep }, size <= cap ? null : Math.max(0, size - keep));
  const { treeBytes, rotateInPlace, keepNewest, removeStale, capByAge, orphanMarks } = await privateOf("ops/storage.ts", {
    // (as the shell states them: no blocks, so each takes its size)
    lstat: async (p: string, o?: unknown) => { const s = await (await import("node:fs/promises")).lstat(p, o as never); return Object.assign(Object.create(Object.getPrototypeOf(s)), s, { blocks: undefined }); },
  }, "storage-noblocks");
  const root = tree();
  const { walkBounded } = await import("../src/ops/walk.ts");
  let bytes = 0;
  const walked = await walkBounded(root, (e) => { if (e.stats !== null) bytes += Number(e.stats.size); }, { stat: true, maxEntries: 1_000_000, maxDepth: 256, maxDurationMs: 60_000 });
  await same({ fn: "treeBytes", path: root }, { bytes, entries: walked.visited, partial: walked.truncated });
  void treeBytes;
  // Two copies of each directory: one for each side.
  const twin = (make: (dir: string) => void) => {
    const a = fresh("twin-a");
    const b = fresh("twin-b");
    make(a);
    make(b);
    return [a, b] as const;
  };
  const dated = (dir: string, names: [string, number][]) => {
    for (const [n, at] of names) {
      writeFileSync(join(dir, n), "y".repeat(100 + at));
      utimesSync(join(dir, n), at, at);
    }
  };
  const [k1, k2] = twin((d) => dated(d, [["config.json.bak-1", 1000], ["config.json.bak-2", 3000], ["config.json.bak-3", 2000], ["config.json.bak-4", 4000], ["config.json", 9000], ["config.json.bak-5", 500]]));
  assert.deepEqual(await mb({ fn: "keepNewest", dir: k2, prefix: "config.json.bak-", kept: 3 }), plain(await keepNewest(k1, "config.json.bak-", 3)));
  const now = 10_000_000;
  const [r1, r2] = twin((d) => dated(d, [[".part-a", 1000], [".part-b", 9000], ["keep", 1], [".part-c", 9999]]));
  assert.deepEqual(await mb({ fn: "removeStale", dir: r2, prefix: ".part-", maxAgeMs: 1_000_000, now }), plain(await removeStale(r1, ".part-", 1_000_000, now)));
  const [c1, c2] = twin((d) => { dated(d, [["t1", 1000], ["t2", 3000], ["t3", 2000], ["t4", 4000]]); mkdirSync(join(d, "sub")); });
  assert.deepEqual(await mb({ fn: "capByAge", dir: c2, max: 500 }), await capByAge(c1, 500));
  for (const d of [c1, c2]) assert.deepEqual(readdirSorted(d), ["sub", "t2", "t4"].filter((n) => readdirSorted(c1).includes(n)));
  const [o1, o2] = twin((d) => {
    writeFileSync(join(d, "live.json"), JSON.stringify({ state: { path: d } }));
    writeFileSync(join(d, "gone.json"), JSON.stringify({ state: { path: join(d, "nowhere") } }));
    writeFileSync(join(d, "bad.json"), "{");
    writeFileSync(join(d, "other.txt"), "x");
  });
  assert.deepEqual(await mb({ fn: "orphanMarks", dir: o2 }), plain(await orphanMarks(o1)));
  const [l1, l2] = twin((d) => writeFileSync(join(d, "stillfail.log"), Array.from({ length: 200 }, (_, i) => `line ${i}\n`).join("")));
  for (const [cap, keep] of [[100_000, 100_000], [500, 300]]) {
    const a = await rotateInPlace(join(l1, "stillfail.log"), cap, keep);
    const b = await mb({ fn: "rotateInPlace", path: join(l2, "stillfail.log"), cap, keep });
    assert.equal(b, a);
    for (const name of ["stillfail.log", "stillfail.log.1"]) assert.equal(tryRead(join(l2, name)), tryRead(join(l1, name)), name);
  }
  for (const dates of [[{ n: "a", at: 1 }, { n: "b", at: 3 }, { n: "c", at: 2 }], []]) for (const kept of [0, 1, 5]) {
    const sorted = [...dates].sort((x, y) => y.at - x.at);
    await same({ fn: "keepNewestPlan", dated: dates, kept }, sorted.slice(kept).map((d) => d.n));
  }
  for (const did of [true, false, [], [1, 2], 0, 5, null, "x"]) {
    const said: { what: string; did: unknown }[] = [];
    const u = await privateOf("ops/storage.ts", {
      log: { info: (_a: string, _b: string, f: { what: string; did: unknown }) => said.push(f), warn: () => {} },
      rotateInPlace: async (p: string) => (p.endsWith("stillfail.log") ? did : false), capByAge: async () => 0, removeStale: async () => [], keepNewest: async () => [], orphanMarks: async () => [],
    }, `step-${JSON.stringify(did)}`);
    const up = new u.Upkeep({ data: "/nonexistent" });
    await up.run();
    await up.close();
    await same({ fn: "upkeepSaid", did }, said.find((x) => x.what === "station log")?.did ?? null);
  }
  for (const runners of [false, true]) for (const remote of [false, true]) for (const checkpoint of [false, true]) {
    const seen: string[] = [];
    const u = await privateOf("ops/storage.ts", {
      log: { info: (_a: string, _b: string, f: { what: string }) => seen.push(f.what), warn: () => {} }, rotateInPlace: async () => true, capByAge: async () => 1, removeStale: async () => ["x"],
      keepNewest: async () => ["x"], orphanMarks: async () => ["x"], walCheckpoint: async () => true, diskOf: async () => null,
    }, `round-${runners}-${remote}-${checkpoint}`);
    const up = new u.Upkeep({ data: "/d", runners: runners ? async () => true : undefined, jobs: async () => true, remote: remote ? async () => true : undefined, checkpoint: checkpoint ? async () => true : undefined });
    await up.run();
    await up.close();
    await same({ fn: "upkeepRound", runners, jobs: true, remote, checkpoint }, seen);
  }
  for (const size of [undefined, 1, 128 * 1024 ** 2, 128 * 1024 ** 2 + 1]) await same({ fn: "walPast", size }, (size ?? 0) > st.WAL_CAP);
});

const readdirSorted = (d: string) => readdirSync(d).sort();
const tryRead = (p: string) => {
  try {
    return readFileSync(p, "utf8");
  } catch {
    return null;
  }
};

test("ops/config.ts: config.json read, edited, refused and read again", { skip }, async () => {
  const { ConfigFile } = await import("../src/ops/config.ts");
  const scripts: { steps: Record<string, unknown>[]; first?: string | null }[] = [
    { first: null, steps: [{ do: "raw" }, { do: "update", set: { language: "en", a: 1 } }, { do: "external", text: '{"b": 2}' }, { do: "raw" }, { do: "update", set: { c: [1, 2] } }, { do: "update", set: { bad: true } }, { do: "raw" }] },
    { first: '{"x": {"y": 1}, "2": "two", "1": "one"}', steps: [{ do: "raw" }, { do: "external", text: "{broken" }, { do: "raw" }, { do: "update", set: { z: 1 } }, { do: "external", text: '{"fixed": true}' }, { do: "raw" }, { do: "update", set: { fixed: null, w: "é" } }] },
    { first: "{not json", steps: [{ do: "raw" }] },
    { first: '{"a":1}', steps: [{ do: "remove" }, { do: "raw" }, { do: "update", set: { n: 1 } }, { do: "external", text: '{"n":1}' }, { do: "raw" }] },
  ];
  let stamp = 1_700_000_000;
  for (const s of scripts) {
    const sides = [fresh("config-ts"), fresh("config-mb")];
    const write = (d: string, text: string) => {
      writeFileSync(join(d, "config.json.new"), text);
      renameSync(join(d, "config.json.new"), join(d, "config.json"));
      stamp += 10;
      utimesSync(join(d, "config.json"), stamp, stamp);
    };
    const prepare = (d: string) => { if (s.first !== undefined && s.first !== null) write(d, s.first); };
    prepare(sides[0]!);
    // TypeScript's side, step by step.
    const told: unknown[] = [];
    const outs: unknown[] = [];
    let cfg: InstanceType<typeof ConfigFile> | null = null;
    const invalid = tr("zh", "station.files.invalidJson", { path: join(sides[0]!, "config.json"), program: process.execPath });
    try {
      cfg = new ConfigFile(sides[0]!);
    } catch (e) {
      const mbAnswer = (prepare(sides[1]!), await mb({ fn: "config", data: sides[1]!, invalid: tr("zh", "station.files.invalidJson", { path: join(sides[1]!, "config.json"), program: process.execPath }), steps: [] }));
      assert.equal(mbAnswer.error.replace(sides[1]!, "<d>"), (e as Error).message.replace(sides[0]!, "<d>"));
      continue;
    }
    cfg.check = (raw) => { if (raw?.bad !== undefined) throw new Error("refused: bad"); };
    cfg.listen((v) => told.push(structuredClone(v)));
    const mbSteps: Record<string, unknown>[] = [];
    const tsSteps: (() => unknown)[] = [];
    for (const step of s.steps) {
      if (step.do === "external" || step.do === "remove") {
        mbSteps.push({ do: "wait" });
        tsSteps.push(() => { step.do === "remove" ? rmSync(join(sides[0]!, "config.json"), { force: true }) : write(sides[0]!, step.text as string); return null; });
      } else {
        mbSteps.push(step);
        tsSteps.push(() => {
          if (step.do === "raw") return cfg!.raw();
          return cfg!.update((raw) => {
            for (const [k, v] of Object.entries(step.set as Record<string, unknown>)) {
              if (v === null) delete raw[k];
              else raw[k] = v;
            }
          });
        });
      }
    }
    for (const f of tsSteps) {
      try {
        outs.push({ ok: plain(f()) });
      } catch (e) {
        outs.push({ error: (e as Error).message.replace(sides[0]!, "<d>") });
      }
    }
    // MoonBit's side: the same steps, the outside edits made between them as the program goes (one case a step).
    prepare(sides[1]!);
    // The program's config is held from one case to the next (`hold`), the outside edits made between them.
    const answer = await mbScript(sides[1]!, s.steps, write);
    assert.deepEqual(answer.steps.map((x: any) => ("error" in x ? { error: x.error.replace(sides[1]!, "<d>") } : x)), outs.filter((_, i) => !["external", "remove"].includes(s.steps[i]!.do as string)), `config ${JSON.stringify(s.steps)}`);
    assert.deepEqual(answer.told, plain(told), `config told ${JSON.stringify(s.steps)}`);
  }
});


/// A config script run by the program: what is done outside it (an edit, a removal) is done here between the cases
/// that make up its steps, each of which takes up the config where the one before left it (`hold`).
async function mbScript(dir: string, steps: Record<string, unknown>[], write: (d: string, t: string) => void) {
  const invalid = tr("zh", "station.files.invalidJson", { path: join(dir, "config.json"), program: process.execPath });
  const out: unknown[] = [];
  let told: unknown[] = [];
  let pending: Record<string, unknown>[] = [];
  let made = false;
  const flush = async () => {
    if (pending.length === 0 && made) return;
    made = true;
    const a = await mb({ fn: "config", data: dir, invalid, refuse: ["bad"], steps: pending, hold: true });
    out.push(...a.steps);
    told = told.concat(a.told);
    pending = [];
  };
  await flush();
  for (const step of steps) {
    if (step.do === "external" || step.do === "remove") {
      await flush();
      if (step.do === "remove") rmSync(join(dir, "config.json"), { force: true });
      else write(dir, step.text as string);
    } else pending.push(step);
  }
  await flush();
  await mb({ fn: "configRelease" });
  return { steps: out, told };
}

// ── ops/places.ts, shell-path.ts, log-export.ts, telemetry.ts, self-memory.ts, awake.ts, heap.ts, links.ts ──

test("ops/places.ts: a path walked link by link, and why a place is refused", { skip }, async () => {
  const { follow, walk } = await import("../src/ops/places.ts");
  const root = tree();
  const prot = join(root, "f");
  const locked = { [prot]: prot, [join(root, "a", "b")]: join(root, "a", "b") };
  const helper = [prot];
  const lock = (p: string) => {
    for (const [at, top] of Object.entries(locked)) if (p === at || p.startsWith(`${at}/`)) return { top, helper: helper.includes(top) };
    return null;
  };
  const loop = join(fresh("loop"), "x");
  symlinkSync(loop, loop);
  for (const path of [root, join(root, "a"), join(root, "e", "to-a"), join(root, "e", "to-a", "b", "c"), join(root, "a", "d", "up", "e"), join(root, "dangling"), join(root, "zz"), join(root, "f", "g"), "relative/x", join(root, "a", "..", "e"), loop, join(root, "missing", "x")]) {
    await same({ fn: "placeFollow", path, cwd: process.cwd(), locked, helper }, await follow(path, lock), `follow ${path}`);
    await same({ fn: "placeWalk", path, cwd: process.cwd(), locked, helper }, await walk(path, lock), `walk ${path}`);
  }
  await mb({ fn: "catalog", zh: ZH, en: EN });
  const pm = await privateOf("ops/places.ts", { hostname: () => "mac-mini.local", platform: { hasFolderPermissions: true } }, "places");
  const places = new pm.Places({ mac: true, home: "/Users/x", timeoutMs: 4200 });
  for (const code of ["gone", "not_a_directory", "not_a_file", "too_large", "denied", "timeout"]) {
    for (const asker of [{ lang: "zh" }, { lang: "en" }, { lang: "zh", agent: true }]) {
      const m = await privateOf("ops/places.ts", { hostname: () => "mac-mini.local", unreadableDirMessage: (lang: string, path: string) => `unreadable ${lang} ${path}` }, "places-refused");
      const p = new m.Places({ mac: true, home: "/Users/x", timeoutMs: 4200 });
      // #refused is private: its words come out of `directory` and `file` as they refuse.
      let words: string;
      if (code === "denied") words = `unreadable ${asker.agent ? "en" : asker.lang} /p`;
      else {
        const key = { gone: "station.place.gone", not_a_directory: "station.place.notDir", not_a_file: "station.place.notFile", too_large: "station.place.tooLarge", timeout: "station.place.timeout" }[code]!;
        words = tr(asker.agent ? "en" : (asker.lang as "zh" | "en"), key, { cwd: "/p", seconds: Math.ceil(4200 / 1000), machine: "mac-mini" });
      }
      void p;
      await same({ fn: "placeRefused", code, path: "/p", lang: asker.lang, agent: asker.agent === true, timeoutMs: 4200, machine: "mac-mini", argv: [], folderPermissions: false }, code === "denied" ? tr(asker.agent ? "en" : (asker.lang as "zh" | "en"), "station.session.cwdDenied", { cwd: "/p" }) : words, `refused ${code} ${JSON.stringify(asker)}`);
    }
  }
  // The refusals as Places makes them, on Linux's way (no protected folders): gone, not a directory, denied.
  const plain_ = new pm.Places({ mac: false });
  for (const [path, code] of [[join(root, "missing"), "gone"], [join(root, "zz"), "not_a_directory"]] as const) {
    for (const lang of ["zh", "en"] as const) {
      let message = "";
      try {
        await plain_.directory(path, { lang });
      } catch (e) {
        message = (e as Error).message;
      }
      await same({ fn: "placeRefused", code, path, lang, agent: false, timeoutMs: 5000, machine: "m", argv: [], folderPermissions: false }, message);
    }
  }
  void places;
  const home = realpathSync(fresh("home"));
  mkdirSync(join(home, "Documents", "sub"), { recursive: true });
  for (const window of ["up", "closed", "none"]) for (const agent of [false, true]) for (const grant of ["documents", "desktop"]) {
    const m = await privateOf("ops/places.ts", { hostname: () => "box" }, "needs");
    let message = "";
    const p = new m.Places({
      mac: true, home,
      helper: { request: async () => { throw Object.assign(new Error("grant"), { code: "grant", grant, top: join(home, "Documents") }); }, ask: async () => window, fs: () => ({}) },
    });
    try {
      await p.directory(join(home, "Documents", "sub"), { lang: "zh", agent });
    } catch (e) {
      message = (e as Error).message;
    }
    await same({ fn: "placeNeeds", grant, top: join(home, "Documents"), window, path: join(home, "Documents", "sub"), lang: "zh", agent, machine: "box" }, message, `needs ${window} ${agent} ${grant}`);
  }
  for (const [stdout, dir] of [['noise\n{"state":"ok","real":"/r"}\n', "/d"], ['{"state":"gone"}', "/d"], ['{"state":"error","error":"EIO: x"}', "/d"], ["", "/d"], ['{"state":"ok"}', "/d"], ['{"state":"denied"}\n', "/d"]] as const) {
    const m = await privateOf("ops/places.ts", { execFile: (_c: string, _a: string[], _o: unknown, cb: (e: Error | null, out: string) => void) => { cb(null, stdout); return { pid: 1 }; } }, `child-${stdout}`);
    const p = new m.Places({ mac: true, home });
    let got: unknown;
    try {
      got = { ok: await p.directory(join(home, "Documents", "sub"), { lang: "en", self: true }).then((real: string) => ({ state: "ok", real }), (e: Error & { code?: string }) => { if (e.code !== undefined) return { state: e.code === "not_a_directory" ? "not_a_directory" : e.code }; throw e; }) };
    } catch (e) {
      got = { error: (e as Error).message };
    }
    await same({ fn: "placeDirAnswer", stdout, dir: join(home, "Documents", "sub") }, got, `child ${stdout}`);
    void dir;
  }
  for (const h of ["mac.local", "box", "a.local.x"]) await same({ fn: "placeMachine", hostname: h }, h.replace(/\.local$/, ""));
});

test("ops/shell-path.ts: a shell's PATH read and used", { skip }, async () => {
  const sp = await privateOf("ops/shell-path.ts", {}, "shell");
  const env = { PATH: "/bin", GITHUB_TOKEN: "t", MY_KEY: "k", KEYBOARD: "x", API_KEY_ID: "i", SECRET_X: "s", HOME: "/h", CODEX_HOME: "/c", CLAUDE_CONFIG_DIR: "/d", oauth_thing: "o", monkey: "m", _KEY: "u" };
  await same({ fn: "probeEnv", env }, sp.probeEnv(env));
  for (const login of [false, true]) {
    let args: string[] = [];
    const m = await privateOf("ops/shell-path.ts", { startCommand: (_s: string, a: string[]) => { args = a; throw new Error("not started"); } }, `args-${login}`);
    await m.readShellPath("/bin/zsh", login, {});
    await same({ fn: "shellProbeArgs", login }, args);
  }
  const marker = "__STILLFAIL_PATH_x__";
  const enc = (v: unknown) => Buffer.from(JSON.stringify(v)).toString("base64");
  for (const [output, code] of [[`motd\n${marker}${enc(["/a", "/b"])}\nbye`, 0], [`${marker}${enc(["/a"])}`, 1], ["no marker", 0], [`${marker}${enc([1])}`, 0], [`${marker}!!!`, 0], [`x\r\n${marker}${enc([])}\r\n`, 0], ["x".repeat(300_000), 0]] as const) {
    // What the shell's output comes to, as readShellPath reads it.
    let expected: string[] | null;
    if (code !== 0 || Buffer.byteLength(output) > 256 * 1024) expected = null;
    else {
      const line = output.split(/\r?\n/).find((s) => s.startsWith(marker));
      try {
        const found: unknown = line ? JSON.parse(Buffer.from(line.slice(marker.length), "base64").toString("utf8")) : null;
        expected = Array.isArray(found) && found.every((p) => typeof p === "string") ? found : null;
      } catch {
        expected = null;
      }
    }
    await same({ fn: "shellPathOf", output, marker, code }, expected);
  }
  for (const [parts, e] of [[["/bin/zsh", false], { b: "1", A: "2", a: "3", _x: "4", Z9: "5" }], [["saved"], {}]] as const) {
    const { createHash } = await import("node:crypto");
    const clean = sp.probeEnv(e);
    const key = createHash("sha256").update(JSON.stringify([...parts, Object.entries(clean).sort(([a], [b]) => a.localeCompare(b))])).digest("hex");
    await same({ fn: "shellKeptKey", parts, env: e }, key);
  }
  // Where a command is found: as given, by the saved PATH, by a shell (plain, then login).
  for (const [has, saved, shellDirs, shell] of [
    [["/bin"], null, null, "/bin/zsh"], [["/saved"], ["/saved"], null, "/bin/zsh"], [["/login"], null, { plain: ["/p1"], login: ["/login", "/l2"] }, "/bin/zsh"],
    [["/p1"], ["/s"], { plain: ["/p1", "/p2"], login: null }, "/bin/zsh"], [["/none"], null, { plain: ["/p1"], login: ["/l"] }, "/bin/zsh"], [["/p1"], null, { plain: ["/p1"] }, null],
  ] as const) {
    const m = await privateOf("ops/shell-path.ts", {
      platform: {
        findCommandSoon: async (_n: string, en: Record<string, string>) => ((en.PATH ?? "").split(":").some((d) => (has as readonly string[]).includes(d)) ? { onPath: "x", real: "x" } : null),
        savedPath: async () => saved, userShell: () => shell, appendPath: (en: Record<string, string>, d: string) => { const p = en.PATH ?? ""; if (!p.split(":").includes(d)) en.PATH = p === "" ? d : `${p}:${d}`; },
        prependPath: (en: Record<string, string>, d: string) => ({ ...en, PATH: `${d}:${en.PATH ?? ""}` }),
      },
      readShellPath: async (_s: string, login: boolean) => (shellDirs === null ? null : ((shellDirs as Record<string, readonly string[] | null>)[login ? "login" : "plain"] ?? null)),
    }, `with-${JSON.stringify([has, saved, shellDirs, shell])}`);
    m.forgetShellPaths();
    const got = await m.withShellCommand("tool", { PATH: "/bin", HOME: "/h" });
    await same({ fn: "withShellCommand", name: "tool", env: { PATH: "/bin", HOME: "/h" }, has, saved, shellDirs, shell }, got);
  }
});

test("ops/log-export.ts and telemetry.ts: the log as it may leave the machine", { skip }, async () => {
  const { scrubPaths, scrubMessage } = await import("../src/ops/telemetry.ts");
  const { scrubText, record } = await import("../src/ops/log-export.ts");
  const texts = [
    "/Users/alice/x and /home/bob/y:3 and C:\\Users\\Carol\\d and C:/Users/dan/e and C:\\\\Users\\\\eve\\\\f", 'parse "secret stuff" at `here` and “quoted” and 「x」 and \'one', "mail alice@example.com, x.y+z@sub.mail.co.uk;",
    "token sk-ant-api03-abcdefghijklmnopqrstuvwxyz and ghp_1234567890abcdefghij and eyJhbGciOiJIUzI1.eyJzdWIiOiIxMjM0.sig-_x AKIAABCDEFGHIJKLMNOP more", "profile alice-example-com and bob-mail-co and not-a-thing and x-y-z-io",
    "x".repeat(2100), "no@domain and @lone and a@b.c and a@b.cd", "/home/ and /Users/:x", "task-abcdefghijklmnopqrst", "AKIA0123456789ABCDEFG", "e-mail sk_live_0123456789abcdefgh",
  ];
  for (const t of texts) for (const home of ["", "/Users/alice", "/"]) {
    await same({ fn: "scrubPaths", text: t, home }, scrubPaths(t, home), `scrubPaths ${t.slice(0, 30)} ${home}`);
    await same({ fn: "scrubMessage", text: t, home }, scrubMessage(t, home), `scrubMessage ${t.slice(0, 30)}`);
    await same({ fn: "scrubText", text: t, home }, scrubText(t, home), `scrubText ${t.slice(0, 30)}`);
  }
  const lines = [
    { ms: 1_790_000_000_123.4, level: "WARN" as const, at: "cloud", message: "presence lost for alice@example.com", fields: { error: "ECONNRESET", text: "people's words", workspace: "not-an-id", n: 3, f: 1.5, ok: true, nested: { name: "x", path: "/Users/alice/y" }, list: ["/home/z/q", 2], und: undefined } },
    { ms: 0, level: "INFO" as const, at: "x", message: "", fields: { workspace: "01ARZ3NDEKTSV4RRFFQ69G5FAV", big: 2 ** 60 } },
    { ms: 5, level: "ERROR" as const, at: "y", message: "e", fields: {} },
  ];
  for (const l of lines) await same({ fn: "logRecord", line: l, home: "/Users/alice" }, record(l, "/Users/alice"));
  // The export's batches: what waits, what is dropped, what is sent again.
  const { LogExport } = await privateOf("ops/log-export.ts", { wall: { now: () => 1_790_000_000_000, every: () => () => {} }, process: { env: { HOME: "/Users/alice" }, stderr: { write: () => {} } } }, "export");
  const scripts = [
    [{ do: "add", line: lines[0], enabled: true }, { do: "configure" }, { do: "add", line: lines[0], enabled: true }, { do: "add", line: lines[1], enabled: false }, { do: "send", enabled: true, station: "S", version: "0.1.2", statuses: [-1] }],
    [{ do: "configure" }, { do: "addMany", line: lines[2], count: 5003 }, { do: "send", enabled: true, station: null, version: "v", statuses: [] }, { do: "send", enabled: true, station: "S", version: "v", statuses: [0] }, { do: "send", enabled: true, station: "S", version: "v", statuses: [-1, 400, -1] }],
    [{ do: "configure" }, { do: "addMany", line: lines[2], count: 1200 }, { do: "send", enabled: true, station: "S", version: "v", statuses: [-1, 429] }, { do: "send", enabled: false, station: "S", version: "v", statuses: [] }],
  ];
  for (const steps of scripts) {
    const e = new LogExport();
    const sent: string[][] = [];
    let enabledNow = true;
    let stationNow: string | null = null;
    let versionNow = "";
    for (const step of steps as Record<string, any>[]) {
      if (step.do === "configure") e.configure({ enabled: () => enabledNow, station: () => stationNow, version: () => versionNow, home: "/Users/alice" });
      else if (step.do === "add") { enabledNow = step.enabled; e.add(step.line); enabledNow = true; }
      else if (step.do === "addMany") for (let i = 0; i < step.count; i++) e.add(step.line);
      else {
        enabledNow = step.enabled;
        stationNow = step.station;
        versionNow = step.version;
        const bodies: string[] = [];
        let k = 0;
        e.sendWith(async (body: string) => {
          bodies.push(body);
          const st = step.statuses[k++];
          if (st === undefined || st < 0) return;
          throw Object.assign(new Error("no"), st === 0 ? {} : { status: st });
        });
        await e.flush();
        sent.push(bodies);
        enabledNow = true;
      }
    }
    const got = await mb({ fn: "logExport", home: "/Users/alice", steps: (steps as Record<string, any>[]).map((s) => (s.do === "send" ? { ...s, now: 1_790_000_000_000 } : s)) });
    assert.deepEqual(got.sent, sent, `logExport ${JSON.stringify(steps).slice(0, 80)}`);
    assert.equal(got.waiting, (e as any).waiting.length);
    assert.equal(got.dropped, (e as any).dropped);
  }
  for (const status of [undefined, 400, 404, 429, 500, 399]) {
    const m = await privateOf("ops/log-export.ts", {}, "refused");
    await same({ fn: "logRefused", status }, m.refused(status === undefined ? new Error("x") : { status }));
  }
  // Error reports: the event a report makes.
  const posted: any[] = [];
  const { ErrorReports } = await privateOf("ops/telemetry.ts", {
    randomUUID: () => "anon-1", wall: { now: () => 1_790_000_000_000 }, fetch: async (_u: string, init: { body: string }) => { posted.push(JSON.parse(init.body)); return { ok: true }; },
  }, "reports");
  for (const [log, error, station] of [["boom (path=/Users/alice/x)", "Unexpected token \"x\" at /Users/alice/y", "S1"], ["only the log", null, null]] as const) {
    const r = new ErrorReports({ key: { host: "https://ph", key: "k", release: "r1" }, enabled: () => true, station: () => station, home: "/Users/alice" });
    posted.length = 0;
    r.report(log, error);
    await r.shutdown();
    const event = posted[0]?.batch[0] ?? null;
    await same({ fn: "errorEvent", log, error, station, anonymous: "anon-1", release: "r1", home: "/Users/alice", now: 1_790_000_000_000 }, event);
    await r.shutdown();
  }
  for (const t of [null, '{"host":"h","key":"k","release":"r"}', '{"host":"h"}', "x"]) {
    const m = await privateOf("ops/telemetry.ts", { readFileSync: () => { if (t === null) throw new Error("none"); return t; } }, `key-${t}`);
    await same({ fn: "builtKey", text: t }, m.builtKey("/ui"));
  }
});

test("ops/self-memory.ts, awake.ts, heap.ts, links.ts", { skip }, async () => {
  const sm = await import("../src/ops/self-memory.ts");
  const G = 1024 ** 3;
  for (const total of [4 * G, 16 * G, 64 * G, 0]) await same({ fn: "limits", total }, { soft: sm.softLimitOf(total), hardRss: sm.hardRssOf(total), hardFront: sm.hardFrontOf(total) });
  const runs = [
    { total: 16 * G, evict: true, restartFront: true, launcher: true, samples: [
      { now: 0, rss: 1 * G, heap: 0.1 * G, children: 0.5 * G, front: 0.2 * G, pressure: "normal" }, { now: 30_000, rss: 3 * G, heap: 0.1 * G, children: 0.5 * G, front: null, pressure: "normal" },
      { now: 60_000, rss: 3 * G, heap: 0.1 * G, children: 0.5 * G, front: null, pressure: "high" }, { now: 90_000, rss: 3 * G, heap: 0.1 * G, children: 0.5 * G, front: null, pressure: "critical" },
      { now: 700_000, rss: 6 * G, heap: 0.1 * G, children: 0, front: 4 * G, pressure: null }, { now: 730_000, rss: 6 * G, heap: 0.1 * G, children: 0, front: 4 * G, pressure: null },
      { now: 760_000, rss: 6 * G, heap: 3 * G, children: 0, front: 4 * G, pressure: null }, { now: 790_000, rss: 6 * G, heap: 0.1 * G, children: 0, front: 4 * G, pressure: null },
      { now: 820_000, rss: 6 * G, heap: 0.1 * G, children: 0, front: 0, pressure: null }, { now: 850_000, rss: 6 * G, heap: 0.1 * G, children: 0, front: 0, pressure: null },
    ] },
    { total: 8 * G, evict: false, restartFront: false, launcher: false, samples: Array.from({ length: 8 }, (_, i) => ({ now: 600_000 + i * 30_000, rss: 4 * G, heap: 0, children: 0, front: 2 * G, pressure: i % 2 ? "high" : null })) },
    { total: 8 * G, evict: true, restartFront: false, launcher: true, samples: Array.from({ length: 7 }, (_, i) => ({ now: 600_000 + i * 30_000, rss: 4 * G, heap: 0, children: 0, front: null, pressure: null, handoverFails: i === 2 })) },
  ];
  for (const run of runs) {
    let now = 0;
    let trims = 0;
    let evicts = 0;
    let i = 0;
    let s: (typeof run.samples)[number] = run.samples[0]!;
    const m = await privateOf("ops/self-memory.ts", { Fibers: class { now() { return now; } every() { return () => {}; } async close() {} }, log: { info: () => {}, warn: () => {} } }, `gov-${runs.indexOf(run)}`);
    const g = new m.SelfMemoryGovernor({
      totalBytes: run.total, startedAt: 0, memory: () => ({ rss: s.rss, heapUsed: s.heap, external: 0, arrayBuffers: 0 }), children: async () => ({ bytes: s.children, count: 1 }),
      front: async () => s.front, ...(run.restartFront ? { restartFront: async () => {} } : {}), pressure: async () => s.pressure, trimIdle: () => ++trims,
      ...(run.evict ? { evictWarm: () => ++evicts } : {}),
      handover: async () => (run.launcher ? async () => { if ((s as { handoverFails?: boolean }).handoverFails) throw new Error("x"); } : null),
    });
    const verdicts: unknown[] = [];
    for (i = 0; i < run.samples.length; i++) {
      s = run.samples[i]!;
      now = s.now;
      verdicts.push(await g.sample());
    }
    await same({ fn: "selfMemory", total: run.total, startedAt: 0, evict: run.evict, restartFront: run.restartFront, launcher: run.launcher, samples: run.samples }, verdicts, `selfMemory ${JSON.stringify(run).slice(0, 60)}`);
  }
  const { working } = await import("../src/ops/awake.ts");
  const now = 10_000_000;
  const stores = [
    { anyRunning: true }, { awakeWait: true }, { awakeWait: false, jobs: [{ sessionKey: "s1", startedAt: now - 1000, watch: true, port: null }], turns: {} },
    { live: ["s1", "s2"], turns: { s1: { declared: "waiting", endedAt: now - 30_000, waitSeconds: 0 }, s2: { declared: "done", endedAt: now - 10 } } },
    { live: ["s1"], turns: { s1: { declared: "waiting", endedAt: now - 3_600_000, waitSeconds: 3500 } } },
    { awakeWait: false, jobs: [{ sessionKey: "s1", startedAt: 0 }], turns: { s1: { declared: "done", endedAt: now - 8_000_000 } } },
    { awakeWait: false, jobs: [{ sessionKey: "s1", startedAt: 0 }], turns: { s1: { declared: "done", endedAt: null } } }, { live: [], turns: {} },
  ];
  for (const st of stores as Record<string, any>[]) {
    const store = {
      anyRunning: () => st.anyRunning === true, liveSessions: () => (st.live ?? []).map((key: string) => ({ key })),
      lastTurnsOf: (keys: string[]) => new Map(keys.filter((k) => st.turns?.[k] !== undefined).map((k) => [k, st.turns[k]])),
      jobsRunning: () => [], ...(st.awakeWait !== undefined ? { awakeWait: () => st.awakeWait, awakeJobs: () => st.jobs ?? [] } : {}),
    };
    await same({ fn: "awakeWorking", anyRunning: st.anyRunning === true, awakeWait: st.awakeWait, jobs: st.jobs ?? [], live: st.live ?? [], turns: st.turns ?? {}, now }, working(store as never, now), `awake ${JSON.stringify(st)}`);
  }
  for (const canHold of [true, false]) {
    let t = 0;
    let isWorking = false;
    const did: (string | null)[] = [];
    const am = await privateOf("ops/awake.ts", { log: { info: () => {}, warn: () => {} } }, "awake");
    const a = new am.Awake({ working: () => isWorking, hold: () => (canHold ? () => did.push("release-fn") : null), fibers: { now: () => t, every: () => () => {}, close: async () => {} } });
    const checks = [{ now: 0, working: true }, { now: 20_000, working: false }, { now: 59_000, working: false }, { now: 61_000, working: false }, { now: 62_000, working: true }, { now: 63_000, working: true }, { now: 200_000, working: false }];
    const states: (string | null)[] = [];
    for (const c of checks) {
      t = c.now;
      isWorking = c.working;
      const before = a.held;
      const releases = did.length;
      a.check();
      states.push(!before && a.held ? "hold" : before && !a.held && did.length > releases ? "release" : null);
    }
    const got = await mb({ fn: "awake", canHold, checks });
    assert.deepEqual(got.map((x: string | null) => (x === "cannot" ? null : x)), states, `awake ${canHold}`);
  }
  for (const names of [["heap-2026.heapsnapshot", "heap-.heapsnapshot", "x-heap-1.heapsnapshot", "heap-1.heapsnapshotx", "heap.request", "heap-a\nb.heapsnapshot"]]) await same({ fn: "heapNames", names }, names.filter((n) => /^heap-.*\.heapsnapshot$/.test(n)));
  for (const ms of [1_790_000_123_456, 0]) await same({ fn: "heapSnapshotPath", dir: "/d/run", now: ms }, join("/d/run", `heap-${new Date(ms).toISOString().replace(/[:.]/g, "-")}.heapsnapshot`));
  for (const answer of [null, { error: "no room" }, { path: "/d/run/heap-x.heapsnapshot", bytes: 157_286_400, ms: 4321 }]) {
    const said: string[] = [];
    const hm = await privateOf("ops/heap.ts", {
      rm: async () => {}, writePrivateSoon: async () => {}, utimes: async () => {}, console: { log: (t: string) => said.push(t), error: (t: string) => said.push(t) },
      readFile: async () => { if (answer === null) throw new Error("none"); return JSON.stringify(answer); }, wall: { now: () => 0, sleep: async () => {} },
    }, `heap-${JSON.stringify(answer)}`);
    const code = await hm.heapCommand("/d", answer === null ? 0 : 1000);
    await same({ fn: "heapCommandEnd", answer }, [said[0], code]);
  }
  const hd = fresh("heap");
  writeFileSync(join(hd, "heap.request"), "1");
  await same({ fn: "heapTake", dir: hd, pid: 77 }, true);
  await same({ fn: "heapTake", dir: hd, pid: 77 }, false);
  for (const junction of [false, true]) for (const copy of [false, true]) for (const target of [null, "dir", "file"]) {
    const lm = await privateOf("ops/links.ts", {
      platform: { linkRefused: () => true }, stat: async () => { if (target === null) throw new Error("none"); return { isDirectory: () => target === "dir" }; }, copyFile: async () => {},
    }, `link-${target}`);
    const made = await lm.link("t", "/x/p", { junction, copy }, async (_t: string, _p: string, type?: string) => { if (type === undefined) throw new Error("EPERM"); });
    await same({ fn: "linkStandIn", junction, copy, target }, made);
  }
});

// ── resources/ ──

const PROCS = [
  { pid: 1, ppid: 0, pgid: 1, bytes: 100, command: "/sbin/launchd" },
  { pid: 10, ppid: 1, pgid: 10, bytes: 1000, command: "/opt/stillfail/stillfail-station" },
  { pid: 11, ppid: 10, pgid: 10, bytes: 2000, command: "/opt/node" },
  { pid: 12, ppid: 10, pgid: 10, bytes: 3000, command: "/opt/stillfail-reader" },
  { pid: 13, ppid: 11, pgid: 10, bytes: 4000, command: "/opt/stillfail-reader" },
  { pid: 20, ppid: 1, pgid: 20, bytes: 500, command: "/opt/stillfail-runner" },
  { pid: 21, ppid: 20, pgid: 21, bytes: 600, command: "/usr/bin/claude" },
  { pid: 22, ppid: 21, pgid: 21, bytes: 700, command: "/usr/bin/git" },
  { pid: 30, ppid: 1, pgid: 30, bytes: 800, command: "/bin/sh" },
  { pid: 31, ppid: 30, pgid: 30, bytes: 900, command: "/usr/bin/make" },
  { pid: 40, ppid: 1, pgid: 40, bytes: 50, command: "/Applications/still.fail.app/Contents/MacOS/still.fail" },
  { pid: 41, ppid: 40, pgid: 40, bytes: 60, command: "/Applications/still.fail.app/Contents/Frameworks/Helper" },
  { pid: 50, ppid: 1, pgid: 50, bytes: 70, command: "/usr/bin/python3" },
  { pid: 51, ppid: 1, pgid: 51, bytes: 80, command: "/usr/bin/nohup" },
  { pid: 60, ppid: 1, pgid: 60, bytes: 90, command: "/usr/bin/runner-agents" },
  { pid: 61, ppid: 60, pgid: 60, bytes: 95, command: "/usr/bin/codex" },
];

test("resources/: what processes use, whose they are", { skip }, async () => {
  const mod = await privateOf("resources/module.ts", {}, "resources");
  const { appBundles, parseNettop, programsIn, frontIn } = await import("../src/resources/module.ts");
  const plists: Record<string, string> = { "/Applications/still.fail.app/Contents/Info.plist": "<string>fail.still.desktop.beta</string>", "/Applications/Other.app/Contents/Info.plist": "x" };
  const commands = ["/Applications/still.fail.app/Contents/MacOS/x", "/Applications/still.fail.app/Contents/MacOS/x", "/Applications/Other.app/Contents/MacOS/y", "/Applications/Other.app/Contents/MacOS/y", "/usr/bin/z", "/Missing.app/Contents/a"];
  const isApp = appBundles(async (p) => { if (plists[p] === undefined) throw new Error("none"); return Buffer.from(plists[p]!); });
  const told: boolean[] = [];
  for (const c of commands) {
    told.push(isApp(c));
    await new Promise((r) => setImmediate(r));
  }
  await same({ fn: "appBundles", commands, plists }, told);
  const ps = " 12 /usr/bin/node --x y\n 7 /bin/sh -c 'a b'\nbad\n  8\n 9 \n 12 again\n";
  await same({ fn: "parseArgs", text: ps }, entries(mod.parseArgs(ps)));
  const nettop = "time,,bytes_in,bytes_out,\nGoogle Chrome H.123,10,20,\nnode.45,0,5\nweird.name.v2.77,1,2,\nx.1,a,2,\nnope\nnode.45,9,9,";
  await same({ fn: "parseNettop", text: nettop }, entries(parseNettop(nettop)));
  for (const pids of [[10], [20, 30], [99], []]) {
    await same({ fn: "programsIn", table: PROCS, pids }, programsIn(PROCS, pids));
    await same({ fn: "programsIn", table: null, pids }, programsIn(null, pids));
  }
  for (const [launcher, self] of [[10, 11], [10, 12], [null, 11], [1, 0]] as const) await same({ fn: "frontIn", table: PROCS, launcher, self }, frontIn(PROCS, launcher, self));
  const { whoseOf, ResourceWatch } = await import("../src/resources/watch.ts");
  const args = [[50, "/usr/bin/python3 /data/sessions/chat-a/run.py"], [51, "/usr/bin/nohup /data/sessions/chat-ab/x"], [30, "/bin/sh -c x"], [61, "codex /data/sessions/chat-a"]] as const;
  const setups = [
    { jobs: [{ session: "S1", pgid: 30 }], runners: [{ runner: 20, pid: 21, session: "S2" }, { runner: 60, pid: 61, session: null }], apps: ["still.fail.app"], self: [10, 11], args, places: [{ dir: "/data/sessions/chat-a", session: "SA" }, { dir: "/data/sessions/chat-ab/", session: "SAB" }] },
    { jobs: [], runners: [], apps: [], self: [], args: null, places: [] },
    { jobs: [], runners: [], apps: [], self: [1], args, places: [] },
    { jobs: [], runners: [], apps: [], self: [], args, places: [], inArguments: true, owners: { "/usr/bin/python3 /data/sessions/chat-a/run.py": "OWN" } },
    { jobs: [], runners: [], apps: [], self: [], args, places: [{ dir: "/data", session: "D" }], inArguments: true },
  ];
  const whoseTs = (s: (typeof setups)[number], table = PROCS) => whoseOf(table, { jobs: () => s.jobs, isApp: (c: string) => s.apps.some((a) => c.includes(a)), self: s.self }, s.runners,
    s.args === null ? null : new Map(s.args.map(([p, l]) => [p, l])), () => s.places, (s as { inArguments?: boolean }).inArguments ? () => ((s as { owners?: Record<string, string> }).owners ? new Map(Object.entries((s as { owners: Record<string, string> }).owners)) : null) : undefined);
  for (const s of setups) await same({ fn: "whoseOf", table: PROCS, ...s }, entries(whoseTs(s)), `whoseOf ${JSON.stringify(s).slice(0, 80)}`);
  // Looks one after another: CPU, memory, disk and network since the last, a pid taken again, one begun meanwhile, a gap.
  const usageAt = (k: number) => Object.fromEntries(PROCS.map((p) => [p.pid, p.pid === 22 && k === 2 ? null : { cpuNs: (p.pid * 1e7) * (k + 1) + (p.pid === 31 && k === 2 ? -1 : 0), footprint: p.bytes * (k + 1), ...(p.pid % 2 ? { diskRead: 100 * k * p.pid, diskWritten: 50 * k } : {}) }]));
  const trafficAt = (k: number) => (k === 1 ? null : [{ pid: 21, in: 1000 * k, out: 10 * k }, { pid: 50, in: 5 * k, out: 0 }]);
  const tableAt = (k: number) => (k === 3 ? PROCS.map((p) => (p.pid === 31 ? { ...p, command: "/usr/bin/other" } : p)) : k === 4 ? null : PROCS.filter((p) => k > 0 || p.pid !== 50));
  const times = [1000, 6000, 11000, 16000, 21000, 60000, 65000];
  const looks = times.map((at, k) => ({ at, table: tableAt(k), usage: usageAt(k), traffic: trafficAt(k), ...setups[0] }));
  let now = 0;
  const w = new ResourceWatch({
    clock: undefined, table: async () => tableAt(cur), args: async () => new Map(setups[0]!.args!.map(([p, l]) => [p, l])), places: () => setups[0]!.places,
    usage: (pids) => pids.map((p) => (usageAt(cur)[p] as never) ?? null), traffic: async () => { const t = trafficAt(cur); return t === null ? null : new Map(t.map((x) => [x.pid, { in: x.in, out: x.out }])); },
    runners: async () => setups[0]!.runners, jobs: () => setups[0]!.jobs, isApp: (c) => c.includes("still.fail.app"), self: setups[0]!.self,
  });
  (w as any).constructor;
  let cur = 0;
  const fibers = { now: () => now, sleep: async () => {}, after: () => () => {}, close: async () => {} };
  Object.defineProperty(w, "__f", { value: fibers });
  const wm = await privateOf("resources/watch.ts", { Fibers: class { now() { return now; } async sleep() {} after() { return () => {}; } async close() {} } }, "watch");
  const watch = new wm.ResourceWatch({
    table: async () => tableAt(cur), args: async () => new Map(setups[0]!.args!.map(([p, l]) => [p, l])), places: () => setups[0]!.places,
    usage: (pids: number[]) => pids.map((p) => (usageAt(cur)[p] as never) ?? null), traffic: async () => { const t = trafficAt(cur); return t === null ? null : new Map(t.map((x) => [x.pid, { in: x.in, out: x.out }])); },
    runners: async () => setups[0]!.runners, jobs: () => setups[0]!.jobs, isApp: (c: string) => c.includes("still.fail.app"), self: setups[0]!.self,
  });
  for (let k = 0; k < times.length; k++) {
    cur = k;
    now = times[k]!;
    await watch.look();
  }
  await same({ fn: "resourceLooks", looks }, watch.snapshot(), "resource looks");
  await w.close();
  await watch.close();
  for (const [pid, session] of [[31, "S1"], [21, "S2"], [20, "S2"], [99, "S1"], [50, "SA"], [31, "S2"], [12, "S1"]] as const) {
    const ew = new wm.ResourceWatch({ table: async () => PROCS, args: async () => new Map(setups[0]!.args!.map(([p, l]) => [p, l])), places: () => setups[0]!.places, usage: () => [], runners: async () => setups[0]!.runners, jobs: () => setups[0]!.jobs, isApp: (c: string) => c.includes("still.fail.app"), self: setups[0]!.self });
    let got: unknown;
    try {
      got = { name: (await ew.end(pid, session, () => {})).name };
    } catch (e) {
      got = { refused: (e as Error).message };
    }
    await same({ fn: "endChoice", table: PROCS, pid, session, ...setups[0] }, got, `end ${pid} ${session}`);
    await ew.close();
  }
  const { ticksOfStat, footprintOfStatus, diskOfIo, linuxUsage } = await import("../src/resources/linux.ts");
  const stats = ["123 (node) S 1 2 3 4 5 6 7 8 9 10 250 50 0 0", "9 (a (weird) name) R 1 2 3 4 5 6 7 8 9 10 11 12 13", "no paren", "5 (x) S 1", "7 (y) S 1 2 3 4 5 6 7 8 9 10 a 3"];
  for (const t of stats) await same({ fn: "ticksOfStat", text: t }, ticksOfStat(t));
  const statuses = ["Name: x\nVmRSS:\t  2048 kB\nRssAnon:\t 1000 kB\nRssShmem: 10 kB\nVmSwap: 5 kB\n", "VmRSS: 64 kB\n", "RssAnon: 3 kB", "nothing", "VmRSS: x kB"];
  for (const t of statuses) await same({ fn: "footprintOfStatus", text: t }, footprintOfStatus(t));
  for (const t of ["rchar: 1\nread_bytes: 4096\nwrite_bytes: 512\n", "read_bytes: 1", "x"]) await same({ fn: "diskOfIo", text: t }, diskOfIo(t));
  for (const [stat, status, io] of [[stats[0], statuses[0], "read_bytes: 1\nwrite_bytes: 2"], [stats[0], null, null], [null, statuses[0], null], [stats[2], null, null]] as const) {
    const files: Record<string, string | null> = { "/proc/7/stat": stat, "/proc/7/status": status, "/proc/7/io": io };
    const [u] = await linuxUsage([7], async (p) => { const t = files[p]; if (t === null || t === undefined) throw new Error("none"); return t; });
    await same({ fn: "linuxUsage", stat, status, io, tick: 1e7 }, u ?? null);
  }
});

// ── search/: the machine's files, a skill read, what is put together ──

test("search/files.ts, skills.ts, search.ts, module.ts", { skip }, async () => {
  const { spotlightQuery, walk: searchWalk } = await import("../src/search/files.ts");
  const fm = await privateOf("search/files.ts", {}, "files");
  for (const words of [["ab"], ["report"], ["a\"b*c?d\\e", "xy"], ["q1", "longer"]]) for (const content of [false, true]) await same({ fn: "spotlightQuery", words, content }, spotlightQuery(words, content) ?? null);
  for (const path of ["/h/code/node_modules/x", "/h/Library/Caches/y", "/h/Apps/X.app/Contents/z", "/Applications/X.app", "/h/doc.txt", "/h/LibraryX/a", "/h/a/.git"]) await same({ fn: "noisy", path, home: "/h" }, fm.noisy(path, "/h"));
  await same({ fn: "mdfindArgs", query: "q", within: ["/a", "/b"] }, ["-0", "-onlyin", "/a", "-onlyin", "/b", "q"]);
  for (const name of ["a.MD", "b.tsx", "c.YAML", "d.png", "noext", ".bashrc", "x.yml"]) await same({ fn: "textName", name }, /\.(md|markdown|txt|text|log|csv|tsv|json|jsonl|ya?ml|toml|ini|conf|cfg|xml|html?|css|scss|less|js|jsx|mjs|cjs|ts|tsx|py|rb|go|rs|java|kt|kts|swift|c|cc|cpp|h|hpp|cs|php|sh|bash|zsh|fish|ps1|sql|r|lua|pl|ex|exs|erl|hs|scala|clj|vue|svelte|tex|rst|org|srt|vtt)$/i.test(name));
  // The home walked: names and small texts with every word, skipping what tools keep and what is hidden.
  const home = realpathSync(fresh("home"));
  for (const [f, t] of [["notes/Report-2026.md", "the quarterly plan"], ["notes/plan.txt", "a Report inside"], ["notes/.hidden/report", "x"], ["node_modules/report/a.js", "report"], ["Library/report.txt", "report"], ["big.log", `report ${"x".repeat(300_000)}`], ["pic.png", "report"], ["dir-report/x", "y"], ["deep/a/b/c/report.md", ""], ["own/report.md", "report"]] as const) {
    mkdirSync(join(home, dirname_(f)), { recursive: true });
    writeFileSync(join(home, f), t);
  }
  for (const [words, most] of [[["report"], 1000], [["report", "plan"], 1000], [["report"], 2], [["nothing"], 1000]] as const) {
    const r = await searchWalk([home], [...words], { skip: [join(home, "own")], most, ms: 3000, now: () => 0 });
    await same({ fn: "searchWalk", tops: [home], words, skip: [join(home, "own")], most }, r, `searchWalk ${words.join(" ")} ${most}`);
  }
  // What is found, ranked and shown.
  const found = ["/h/notes/report.md", "/h/a/b/report-old.md", "/h/other.txt", "/Applications/Report Maker.app", "/h/Library/Mail/report.eml", "/h/own/x", "/h/pinned/sub/report.txt", "/h/gone", "/h/notes/report.md", "/elsewhere/report"];
  const stats: Record<string, { dir: boolean; size: number; at: number }> = {
    "/h/notes/report.md": { dir: false, size: 10, at: 1000.4 }, "/h/a/b/report-old.md": { dir: false, size: 20, at: 3000.6 }, "/h/other.txt": { dir: false, size: 1, at: 5000 },
    "/Applications/Report Maker.app": { dir: true, size: 96, at: 1 }, "/h/Library/Mail/report.eml": { dir: false, size: 5, at: 9 }, "/h/own/x": { dir: false, size: 1, at: 1 },
    "/h/pinned/sub/report.txt": { dir: false, size: 3, at: 7 }, "/elsewhere/report": { dir: false, size: 4, at: 8 },
  };
  for (const [writer, personal, limit, pinned] of [[true, false, 8, []], [true, true, 2, []], [false, false, 8, ["/h/pinned"]], [false, false, 8, []], [true, false, 1, []]] as const) {
    const fs2 = await privateOf("search/files.ts", { stat: async (p: string) => { const s = stats[p]; if (!s) throw new Error("gone"); return { isDirectory: () => s.dir, size: s.size, mtimeMs: s.at }; }, protectedTop: () => null }, `rank-${writer}-${personal}-${limit}-${pinned.join()}`);
    const search = new fs2.FileSearch({ protect: () => ["/h/own"], roots: () => [...pinned], personal: () => personal, home: "/h", spotlight: async () => found, now: () => 0 });
    const got = await search.query(["report"], { workspace: "W", home: true, scopes: writer ? ["read", "write"] : ["read"] }, limit);
    await same({ fn: "fileHits", found, words: ["report"], home: "/h", writer, pinned, protect: ["/h/own"], personal, limit, left: false, stats }, got, `fileHits ${writer} ${personal} ${limit}`);
  }
  for (const [words, writer, open] of [[["ab"], true, []], [["report", "x"], true, []], [["report"], false, ["/p"]], [["ab"], false, ["/p"]], [["report"], false, []]] as const) {
    const asked: unknown[] = [];
    const fs3 = await privateOf("search/files.ts", { stat: async () => { throw new Error("none"); }, protectedTop: () => null }, `asks-${words.join()}-${writer}-${open.join()}`);
    const search = new fs3.FileSearch({ protect: () => [], roots: () => [...open], personal: () => false, home: "/h", spotlight: async (query: string, within: string[], most: number) => { asked.push({ query, within, most }); return []; }, now: () => 0 });
    await search.query([...words], { workspace: "W", home: true, scopes: writer ? ["write"] : ["read"] }, 8);
    await same({ fn: "spotlightAsks", words, writer, home: "/h", open }, asked);
  }
  for (const [words, workspace, home2, writer, limit, personal, roots] of [[["a", "b"], "W", true, true, 8, false, []], [["x"], "V", false, false, 3, true, ["/r"]]] as const) {
    await same({ fn: "fileSearchKey", words, workspace, home: home2, writer, limit, personal, roots }, JSON.stringify([words, workspace, home2, writer, limit, personal, roots]));
  }
  for (const age of [null, 0, 5000, 5001, 20000, 20001, 60000, 60001]) for (const again of [false, true]) for (const guessed of [false, true]) {
    const expected = age !== null && (age <= 5000 || (again && age <= 60000) || (guessed && age <= 20000));
    await same({ fn: "fileSearchReuse", age, again, guessed }, expected);
  }
  // Whose turn: two at once, a typist's search typed on taking the place of the one before.
  const steps = [
    { do: "ask", id: 1, typist: "d1", typed: "re" }, { do: "ask", id: 2, typist: "d2", typed: "x" }, { do: "ask", id: 3, typist: "d1", typed: "rep" }, { do: "ask", id: 4, typist: undefined, typed: "y" },
    { do: "ask", id: 5, typist: "d2", typed: "xy" }, { do: "done", id: 1 }, { do: "done", id: 2 }, { do: "expire", id: 4 }, { do: "done", id: 3 }, { do: "ask", id: 6, typist: "d1", typed: "z" },
  ];
  const tsTurns = (() => {
    const going: { id: number; typist?: string; typed: string }[] = [];
    let waiting: { id: number; typist?: string; typed: string }[] = [];
    const before = (typist: string | undefined, typed: string) => (w: { typist?: string; typed: string }) => typist !== undefined && w.typist === typist && (typed.startsWith(w.typed) || w.typed.startsWith(typed));
    return steps.map((s) => {
      if (s.do === "ask") {
        const b = before(s.typist, s.typed!);
        const stopped = going.filter(b).map((g) => g.id);
        const dropped = waiting.filter(b).map((w) => w.id);
        waiting = waiting.filter((w) => !b(w));
        const goes = going.length < 2;
        (goes ? going : waiting).push({ id: s.id, ...(s.typist !== undefined ? { typist: s.typist } : {}), typed: s.typed! });
        return { stopped, dropped, goes };
      }
      if (s.do === "done") {
        const at = going.findIndex((g) => g.id === s.id);
        if (at < 0) return null;
        going.splice(at, 1);
        const next = waiting.shift();
        if (next) going.push(next);
        return next?.id ?? null;
      }
      waiting = waiting.filter((w) => w.id !== s.id);
      return null;
    });
  })();
  // (the rule is files.ts `#turn`'s and `#next`'s: `before`, AT_ONCE, the waiting's order)
  const turnSrc = readFileSync(join(SRC, "search/files.ts"), "utf8");
  assert.match(turnSrc, /const before = \(w: \{ typist\?: string; typed: string \}\) => typist !== undefined && w\.typist === typist && \(typed\.startsWith\(w\.typed\) \|\| w\.typed\.startsWith\(typed\)\);/);
  assert.match(turnSrc, /export const AT_ONCE = 2;/);
  await same({ fn: "turns", steps }, tsTurns);
  // skills.ts
  const { formatSkillFromCatalog, skillForPeer } = await import("../src/search/skills.ts");
  const catalog = { skills: [{ name: "deploy", text: "# deploy", files: [{ name: "more.md", text: "more" }] }, { name: "x\"y", text: "t", files: [] }] };
  for (const args of [{ name: "deploy" }, { name: " " }, {}, { name: "deploy", file: "" }, { name: "deploy", file: 3 }, { name: "deploy", file: "more.md" }, { name: "deploy", file: "none.md" }, { name: "x\"y" }, { name: "nope" }]) {
    let sel: unknown;
    try {
      const r = await skillForPeer(async () => catalog, args, null, null);
      sel = { ok: r.text };
    } catch (e) {
      sel = { error: (e as Error).message };
    }
    let mbSel = await mb({ fn: "skillSelection", args });
    if (!("error" in mbSel)) {
      const f = await mb({ fn: "formatSkill", catalog, name: mbSel.name, file: mbSel.file });
      mbSel = f;
    }
    assert.deepEqual(mbSel, sel, `skill ${JSON.stringify(args)}`);
    void formatSkillFromCatalog;
  }
  for (const [workspace, home2] of [[null, "H"], ["H", "H"], ["W", "H"], ["W", null]] as const) {
    let asked: string | undefined = "unset";
    await skillForPeer(async (w) => { asked = w; return catalog; }, { name: "deploy" }, workspace, home2);
    await same({ fn: "skillWorkspace", workspace, home: home2 }, asked ?? null);
  }
  const { skillTools } = await import("../src/search/skills.ts");
  const stations = [{ id: "S1", name: "Mac", here: true }, { id: "S2", name: "Box", here: false }, { id: "S3", name: "box", here: false }];
  for (const asked of [undefined, "", "this station", "S1", "s2", "Mac", "BOX", "none"]) {
    let where: unknown;
    const [tool] = skillTools({ workspaceOf: () => ({ workspace: "W", home: true }), readSkill: async () => "here", stations: async () => stations, ask: async (id: string) => ({ text: id }) } as never);
    try {
      const r = await tool!.run("sess", { name: "deploy", ...(asked !== undefined ? { station: asked } : {}) });
      where = { ok: r === "here" ? "here" : r };
    } catch (e) {
      where = { error: (e as Error).message };
    }
    await same({ fn: "skillStation", asked, stations }, where, `skillStation ${asked}`);
  }
  // search.ts: the files beside the rest.
  for (const [files, kinds, limit, offset] of [[true, undefined, undefined, undefined], [true, ["file"], 500, 0], [true, ["chat"], 0, 0], [true, [], 3, 2], [false, ["file", "chat"], 9, 0], [true, ["file", "chat"], -5, 0]] as const) {
    const calls: { files: number | null; program: boolean } = { files: null, program: false };
    const sm = await privateOf("search/search.ts", { MbProcess: class {}, SearchScopeBuilder: class { prepare() { return Promise.resolve(); } async close() {} }, SessionListBuilder: class { readySearch() { return Promise.resolve(); } async close() {} } }, "search-plan");
    const s = new sm.Search({
      data: "/d", files: files ? { query: async (_w: string[], _a: unknown, l: number) => { calls.files = l; return null; } } : null,
      reference: () => ({ on(e: string, f: (a: unknown) => void) { if (e === "message") this.f = f; return this; }, f: (_a: unknown) => {}, postMessage(t: { id: number }) { calls.program = true; this.f({ id: t.id, groups: [] }); }, terminate: async () => 0 }),
    });
    await s.query("words here", { workspace: "W", home: true, scopes: ["write"] }, { kinds: kinds as string[] | undefined, limit, offset });
    await s.stop();
    const got = await mb({ fn: "searchPlan", files, kinds, limit, offset });
    assert.equal(got.program, calls.program, `program ${JSON.stringify([files, kinds])}`);
    assert.equal(got.files, calls.files !== null, `files ${JSON.stringify([files, kinds, offset])}`);
    if (calls.files !== null) assert.equal(got.filesLimit, calls.files);
  }
  const roster = { stations: [{ id: "S1", name: "Mac" }, { id: "" }, { id: "S2" }, { name: "no id" }, { id: "S3", name: 5 }] };
  await same({ fn: "searchStations", roster, station: "S2" }, roster.stations.filter((e: any) => typeof e?.id === "string" && e.id !== "").map((e: any) => ({ id: e.id, name: typeof e.name === "string" ? e.name : e.id, here: e.id === "S2" })));
  for (const [ws, home2] of [[null, "H"], ["H", "H"], ["W", "H"], [null, null]] as const) await same({ fn: "searchWorkspaceOf", ws, home: home2 }, { workspace: ws ?? home2 ?? "", home: ws === null || ws === home2 });
});
const dirname_ = (p: string) => p.split("/").slice(0, -1).join("/") || ".";

// ── read/: what the readers do not answer already ──

test("read/: names books, views' config and authors, the machine's transcripts, a job's log, usage", { skip }, async () => {
  const sk = await import("../src/read/slack-known.ts");
  const config = { connects: [
    { id: "c1", slack: { team: { id: "T1", name: "Team One" }, botName: "Bot One" } }, { id: "c2", kind: "feishu", feishu: { tenant: { name: "飞书" } } }, { id: "c3", kind: "comma" },
    { id: "c4", kind: "group" }, { id: "c5", slack: { team: { id: "" } } }, { id: 6 }, { id: "c7", slack: { botName: "" } },
  ], automaticDecisions: { completion: { enabled: true } } };
  const remote = { r1: { described: { kind: "slack", team: "T9", identity: { team: "Nine" } } }, r2: { described: { kind: "feishu", identity: { team: "远" } } }, r3: { described: { kind: "slack", team: "" } }, c1: { described: { kind: "slack", team: "TX" } } };
  await same({ fn: "configTeams", raw: config }, entries(sk.configTeams(config)));
  await same({ fn: "remoteTeams", raw: remote }, entries(sk.remoteTeams(remote)));
  const all = new Map([...sk.remoteTeams(remote), ...sk.configTeams(config)]);
  await same({ fn: "allTeams", config, remote }, entries(all));
  for (const connect of ["c1", "c1@station", "r1", "x@y", "@c1", "c2"]) await same({ fn: "teamIn", config, remote, connect }, sk.teamIn(all, connect) ?? null);
  const books = { slack: { "u:T1:U1": { person: { name: "Ann", email: "a@x", picture: "p" } }, "u:T9:U2": { person: { name: "Bo" } }, "u:T1:U3": { person: { email: "x" } } }, feishu: { "u:c2:ou_1": { person: { name: "飞" } } } };
  const data = fresh("known");
  writeFileSync(join(data, "slack-names.json"), JSON.stringify(books.slack));
  writeFileSync(join(data, "feishu-names.json"), JSON.stringify(books.feishu));
  writeFileSync(join(data, "remote-connects.json"), JSON.stringify(remote));
  const known = new sk.KnownNames(data, () => config);
  for (const [connect, user] of [["c1", "U1"], ["c1@s", "U1"], ["r1", "U2"], ["c1", "U3"], ["c2", "ou_1"], ["zz", "U1"], ["c1", "nobody"]]) await same({ fn: "knownPerson", config, remote, books, connect, user }, known.person(connect!, user!));
  known.close();
  const { configOf } = await import("../src/read/views.ts");
  for (const raw of [config, null, { connects: "x" }, { automaticDecisions: { completion: { enabled: "yes" } } }]) await same({ fn: "viewsConfig", raw }, configOf(raw as never));
  // Authors' names, as views.ts `authorNames` names them.
  const vm_ = await privateOf("read/views.ts", {}, "views");
  const people: Record<string, { name: string; email: string; picture: string }> = { "c1/U1": { name: "Ann", email: "", picture: "pic" }, "c1/U0": { name: "", email: "", picture: "x" } };
  const cases = [
    { kind: "station", author: "x" }, { kind: "agent", author: "s1", members: [{ session: "s1", connect: "c1" }], sessionConnect: "c2", sessionTitle: "T" },
    { kind: "agent", author: "s1", members: [{ session: "s1", connect: "ember" }], sessionConnect: "c1", sessionTitle: "T" }, { kind: "agent", author: "s2", members: [], sessionConnect: null, sessionTitle: "Title" },
    { kind: "agent", author: "s3", members: [], sessionConnect: "zz", sessionTitle: null }, { kind: "person", author: "local", surface: "ember", admin: "Root" }, { kind: "person", author: "a@x", surface: "ember", names: { "a@x": "Ann X" } },
    { kind: "person", author: "b@x", surface: "ember" }, { kind: "person", author: "U1", surface: "slack", members: [{ session: "s", connect: "ember" }, { session: "s1", connect: "c1" }] },
    { kind: "person", author: "U0", surface: "slack", members: [{ session: "s1", connect: "c1" }] }, { kind: "person", author: "U1", surface: "slack", members: [{ session: "s1", connect: "ember" }] },
  ];
  const connects = [{ id: "c1", name: "Bot One" }, { id: "c2", name: "c2" }];
  for (const c of cases as Record<string, any>[]) {
    const api = {
      store: { names: new Map(Object.entries(c.names ?? {})) }, connects, reviews: false, person: (connect: string, user: string) => people[`${connect}/${user}`] ?? null,
    };
    const m = await privateOf("read/views.ts", {
      store: {
        getThread: () => (c.surface === undefined ? null : { surface: c.surface }), threadSessions: () => c.members ?? [],
        getSession: () => (c.sessionConnect === undefined && c.sessionTitle === undefined ? null : { connect: c.sessionConnect ?? null, title: c.sessionTitle ?? null }),
      },
    }, `author-${JSON.stringify(c)}`);
    const names = m.authorNames(api, 1, c.admin ?? null);
    await same({ fn: "authorName", ...c, connects, people }, { name: names(c.kind, c.author), picture: names.picture(c.kind, c.author) }, `author ${JSON.stringify(c)}`);
  }
  void vm_;
  // The machine's transcripts.
  const mm = await privateOf("read/machine.ts", { process: { env: { HOME: "/h", CODEX_HOME: "" } } }, "roots");
  await same({ fn: "machineRoots", home: "/h", codexHome: "" }, mm.roots());
  const mm2 = await privateOf("read/machine.ts", { process: { env: { CODEX_HOME: "/c" } } }, "roots2");
  await same({ fn: "machineRoots", codexHome: "/c" }, mm2.roots());
  const { extension, rolloutOf, transcriptOf } = await import("../src/read/machine.ts");
  for (const name of ["a.jsonl", ".hidden", "noext", "a.b.c", "x."]) await same({ fn: "extension", name }, extension(name));
  for (const [path, id] of [["/x/rollout-2026-abc.jsonl", "abc"], ["/x/rollout-t-abc_2.jsonl", "abc"], ["/x/rollout-abcd.jsonl", "bcd"], ["/x/y.jsonl", "y"]]) await same({ fn: "rolloutOf", path, id }, rolloutOf(path!, id!));
  const mroot = fresh("machine");
  const claude = join(mroot, ".claude", "projects");
  const codex = join(mroot, ".codex", "sessions");
  for (const [f, at] of [[join(claude, "p1", "s1.jsonl"), 1], [join(claude, "p2", "s1.jsonl"), 2], [join(codex, "2026", "11", "01", "rollout-1-th1.jsonl"), 1_700_000_000], [join(codex, "2026", "11", "02", "rollout-2-th1.jsonl"), 1_700_000_500], [join(codex, "2026", "11", "02", "rollout-3-th1_x.jsonl"), 1_700_000_100]] as const) {
    mkdirSync(join(f, ".."), { recursive: true });
    writeFileSync(f, "{}\n");
    utimesSync(f, at, at);
  }
  for (const [runtime, id] of [["claude", "s1"], ["claude", "none"], ["codex", "th1"], ["codex", "zz"], ["claude", "../x"], ["codex", ""]] as const) {
    await same({ fn: "transcriptOf", claude, codex, runtime, id }, await transcriptOf({ claude, codex }, runtime, id), `transcriptOf ${runtime} ${id}`);
  }
  // A job's log.
  const { outputAt, tail, rustLines } = await import("../src/read/jobs.ts");
  const logs = fresh("logs");
  writeFileSync(join(logs, "empty.log"), "");
  writeFileSync(join(logs, "a.log"), "one\r\ntwo\nthree\n");
  writeFileSync(join(logs, "a.log.1"), "zero\nhalf\n");
  writeFileSync(join(logs, "big.log"), Array.from({ length: 20_000 }, (_, i) => `line ${i}`).join("\n"));
  utimesSync(join(logs, "a.log"), 1_700_000_000.123, 1_700_000_000.123);
  for (const p of ["empty.log", "a.log", "nope.log"]) await same({ fn: "outputAt", path: join(logs, p) }, await outputAt(join(logs, p)));
  for (const [p, lines] of [["a.log", 2], ["a.log", 4], ["a.log", 10], ["big.log", 3], ["big.log", 50_000], ["nope.log", 3]] as const) await same({ fn: "logTail", path: join(logs, p), lines }, await tail(join(logs, p), lines), `tail ${p} ${lines}`);
  for (const t of ["", "a", "a\n", "a\r\nb\r\n", "a\r", "\n\n", "x\ry\r\n"]) await same({ fn: "rustLines", text: t }, rustLines(t));
  // Where a rollout is, a look answered, where a reading is kept.
  const tsm = await privateOf("read/transcript-soon.ts", {}, "soon");
  const zst = join(codex, "2026", "11", "03", "rollout-9-th2.jsonl.zst");
  mkdirSync(join(zst, ".."), { recursive: true });
  writeFileSync(zst, "z");
  for (const look of [{ ask: "there", path: claude }, { ask: "there", path: join(mroot, "no") }, { ask: "file", path: join(claude, "p1", "s1.jsonl") }, { ask: "file", path: claude }, { ask: "names", path: join(claude) }, { ask: "names", path: join(mroot, "no") },
    { ask: "real", path: join(claude, "..", "projects") }, { ask: "rollout", path: codex, id: "th1" }, { ask: "rollout", path: codex, id: "th2" }, { ask: "rollout", path: codex, id: "none" }]) {
    await same({ fn: "lookAnswer", look }, await tsm.answer(look), `look ${JSON.stringify(look)}`);
  }
  const { fileOf, marksDir } = await import("../src/read/transcripts.ts");
  for (const p of ["/a/b.jsonl", "名字.jsonl", ""]) await same({ fn: "markFile", data: "/d", path: p }, fileOf(marksDir("/d"), p));
  // What a session spent.
  const usage = await import("../src/read/usage.ts");
  const { learn, catalog: catalogNow } = await import("../src/accounts/catalog.ts");
  // The catalog as the readers are given it (read/pool.ts `give`: `catalog().models`).
  learn({ "kimi-k2": { cost: { input: 0.6, output: 2.5 } }, "glm-4.6": { cost: { input: 0.5, output: 2, cacheRead: 0.1 } }, "gemini-4-hydrogen": { cost: { input: 1, output: 4 } } });
  const catalog = catalogNow().models;
  for (const model of ["claude-opus-5-5", "anthropic/claude-opus-5-5[1m]", "claude-sonnet-4-5-20250929", "kimi-k2", "glm-4.6", "gemini-4-hydrogen-high", "gpt-6-luna", "unknown", "claude-fable-5-2-max"]) {
    await same({ fn: "modelPrice", model, catalog }, usage.price(model), `price ${model}`);
  }
  const groups = [
    { model: "claude-opus-5-5", fast: false, calls: 3, input: 100, cacheRead: 1000, cacheWrite: 50, cacheWriteLong: 0, output: 20 }, { model: "kimi-k2", fast: true, calls: 1, input: 10, cacheRead: 0, cacheWrite: 0, cacheWriteLong: 5, output: 1 },
    { model: null, fast: false, calls: 2, input: 1, cacheRead: 1, cacheWrite: 1, cacheWriteLong: 1, output: 1 }, { model: "mystery", fast: false, calls: 4, input: 0, cacheRead: 0, cacheWrite: 0, cacheWriteLong: 0, output: 0 },
  ];
  await same({ fn: "sessionUsage", groups, catalog }, usage.sessionUsage(groups as never));
  const contexts = [
    { at: 100, model: "claude-opus-5-5", window: 200000, context: 5000, cacheWrite: 10, cacheWriteLong: 0, fast: false }, { at: 200, model: "claude-opus-5-5", window: 200000, context: 6000, cacheWrite: 0, cacheWriteLong: 5, fast: true },
    { at: 300, model: "mystery", window: null, context: null, cacheWrite: 0, cacheWriteLong: 0, fast: false },
  ];
  for (const [g, ctx, since, saved] of [
    [groups, contexts, 0, null], [groups, contexts, 250, null], [groups, contexts, null, null], [groups, contexts.slice(0, 2), 150, { model: "m2", contextWindow: 9, lastCallAt: 400, contextTokens: 7 }],
    [groups, contexts, 0, { model: "m2", contextWindow: 9, lastCallAt: 250 }], [[], contexts, 0, null], [groups, [], 0, { model: "m3", contextWindow: null, lastCallAt: 1, cacheMs: 5, rereadCost: 0.5 }],
  ] as const) {
    const got = usage.usageNow({ usageOfSession: () => g as never, lastContexts: () => ctx as never, conversationSince: () => since, savedCompactContext: () => saved as never }, "k");
    await same({ fn: "usageNow", groups: g, contexts: ctx, since, saved, catalog }, got, `usageNow ${JSON.stringify([since, saved])}`);
  }
});

test("read/store.ts: a session, a thread and its members, threads with cards", { skip }, async () => {
  const { Store } = await import("../src/store/store.ts");
  const { DatabaseSync } = await import("node:sqlite");
  const rs = await import("../src/read/store.ts");
  const data = fresh("store");
  const path = join(data, "stillfail.db");
  const store = Store.open(path, join(data, "archive"));
  store.close?.();
  const db = new DatabaseSync(path);
  db.exec(`INSERT INTO sessions (key, connect, scope, runtime, profile, title, workspace, token, created_at, last_active_at) VALUES ('s1', 'ember', 'chat', 'claude', 'default', 'Hello', '/w', 'tok', 1, 2)`);
  db.exec(`INSERT INTO threads (id, surface, channel, thread_ts, created_at) VALUES (7, 'ember', 'c', 't', 5), (8, 'slack', 'C1', '1.2', 6)`);
  db.exec(`INSERT INTO thread_sessions (thread, session, connect, joined_at) VALUES (7, 's1', 'ember', 2), (7, 's2', 'c1', 1), (8, 's1', 'c1', 3)`);
  db.exec(`INSERT INTO entries (thread, n, kind, author_kind, author, at, card) VALUES (7, 1, 'message', 'agent', 's1', 1, '{"options":[]}')`);
  db.exec(`INSERT INTO entries (thread, n, kind, author_kind, author, at, options) VALUES (8, 1, 'message', 'agent', 's1', 1, '["a"]')`);
  const s = rs.makeStore(db, data);
  for (const [session, thread] of [["s1", 7], ["none", 8], ["s1", 99]] as const) {
    await same({ fn: "storeReads", db: path, session, thread, threads: [7, 8, 9] }, {
      session: rs.one(s, "SELECT * FROM sessions WHERE key = ?", session) ?? null, thread: rs.one(s, "SELECT * FROM threads WHERE id = ?", thread) ?? null,
      members: rs.all(s, "SELECT * FROM thread_sessions WHERE thread = ? ORDER BY joined_at, rowid", thread), withCards: rs.threadsWithCards(s, [7, 8, 9]),
    }, `store ${session} ${thread}`);
  }
  db.close();
});
