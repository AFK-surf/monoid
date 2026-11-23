// What differs between machines is said in src/platform/ only (src/platform/index.ts), so the station's logic is one
// for macOS, Linux and Windows. And each platform's path rules, which are pure: Windows' are checked on every machine.
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import { portableComponent, portableName } from "../src/ops/paths.ts";
import { elasticMemory, isMonoidStationVm } from "../src/platform/text.ts";
import { elasticMemoryReader, unix } from "../src/platform/unix.ts";
import { cmdPath, drives, gitShell, gitShellSoon, posixShells, readShim, savedPathOf, windows } from "../src/platform/windows.ts";
import { syncCalls } from "./main-thread-sync.ts";

const src = fileURLToPath(new URL("../src", import.meta.url));

function files(dir: string): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap((e) =>
    e.isDirectory() ? files(join(dir, e.name)) : e.name.endsWith(".ts") ? [join(dir, e.name)] : [],
  );
}

test("no code outside src/platform/ asks which machine this is", () => {
  const asks = /process\.platform|\bwin32\b|\bWINDOWS\b|["'`]darwin["'`]/;
  const found: string[] = [];
  for (const file of files(src)) {
    const rel = relative(src, file).replaceAll("\\", "/");
    if (rel.startsWith("platform/")) continue;
    readFileSync(file, "utf8").split("\n").forEach((line, i) => {
      // What a comment says is not code.
      if (line.trim().startsWith("//")) return;
      if (asks.test(line)) found.push(`src/${rel}:${i + 1}: ${line.trim()}`);
    });
  }
  assert.deepEqual(found, [], "ask platform (src/platform/index.ts) instead:\n" + found.join("\n"));
});

test("whether a path is rooted is the machine's to say, not a leading /", () => {
  // `p.startsWith("/") ? p : join(base, p)` takes C:\… for relative on Windows and joins it again (a borrowed
  // subscription's home was made at <data>\C:\…\homes\…): ops/paths.ts joinPath, or path's isAbsolute.
  const joinsUnlessSlash = /startsWith\(["'`]\/["'`]\)\s*\?\s*[\w.]+\s*:\s*join\(/;
  const found: string[] = [];
  for (const file of files(src)) {
    const rel = relative(src, file).replaceAll("\\", "/");
    if (rel.startsWith("platform/")) continue;
    readFileSync(file, "utf8").split("\n").forEach((line, i) => {
      if (joinsUnlessSlash.test(line)) found.push(`src/${rel}:${i + 1}: ${line.trim()}`);
    });
  }
  assert.deepEqual(found, [], "join with ops/paths.ts joinPath instead:\n" + found.join("\n"));
});

test("a group of processes is started and ended in ops/processes.ts only", () => {
  // The runner starts apart from the rest (agents/runner.ts): it is no group of a command's, but what agents run under.
  const allowed = new Set(["ops/processes.ts", "agents/runner.ts"]);
  const found: string[] = [];
  for (const file of files(src)) {
    const rel = relative(src, file).replaceAll("\\", "/");
    if (rel.startsWith("platform/") || allowed.has(rel)) continue;
    readFileSync(file, "utf8").split("\n").forEach((line, i) => {
      if (line.trim().startsWith("//")) return;
      if (/platform\.grouped\(|platform\.signalChildGroup\(|detached:\s*true/.test(line)) found.push(`src/${rel}:${i + 1}: ${line.trim()}`);
    });
  }
  assert.deepEqual(found, [], "start it with startCommand or startLasting (src/ops/processes.ts):\n" + found.join("\n"));
});

test("paths join as Rust's Path::join does, on each machine", () => {
  assert.equal(unix.paths.join("/a/b", "c"), "/a/b/c");
  assert.equal(unix.paths.join("/a/b/", "c"), "/a/b/c");
  assert.equal(unix.paths.join("/a", "/c"), "/c");
  assert.equal(unix.paths.join("", "c"), "c");
  assert.equal(windows.paths.join("C:\\a", "c"), "C:\\a\\c");
  assert.equal(windows.paths.join("C:\\a\\", "c"), "C:\\a\\c");
  assert.equal(windows.paths.join("C:\\a", "D:\\c"), "D:\\c");
  // Nothing normalised, as Rust has it.
  assert.equal(windows.paths.join("C:\\a", "b/../c"), "C:\\a\\b/../c");
});

test("a path given as relative is rooted when it starts somewhere of its own", () => {
  for (const p of ["/etc/passwd"]) assert.ok(unix.paths.rooted(p) && windows.paths.rooted(p), p);
  for (const p of ["a/b", "a\\b", "a:b"]) assert.ok(!unix.paths.rooted(p), p);
  // A drive, a drive-relative path, a share, a stream.
  for (const p of ["C:\\x", "C:x", "\\\\server\\share\\x", "file:stream"]) assert.ok(windows.paths.rooted(p), p);
  assert.ok(!windows.paths.rooted("a\\b"));
});

test("a portable name is one on every machine, in any script; anything else made one without two coming to the same", () => {
  for (const name of ["测试", "ember", "a b", "v1.2", "con-notes"]) assert.ok(portableName(name), name);
  for (const name of ["", ".hidden", "..", "a/b", "a\\b", "a:b", "what?", "trailing.", "trailing ", "CON", "nul.txt", "com1", "x".repeat(256)]) assert.equal(portableName(name), false, name);
  assert.equal(portableComponent("构建"), "构建");
  const [x, y] = [portableComponent("a:b"), portableComponent("a?b")];
  assert.ok(portableName(x) && portableName(y));
  assert.notEqual(x, y);
});

test("a path inside a root is told by whole components, as each machine compares them", () => {
  assert.equal(unix.paths.relativeIn("/w/s", "/w/s/a/b"), "a/b");
  assert.equal(unix.paths.relativeIn("/w/s", "/w/s"), "");
  assert.equal(unix.paths.relativeIn("/w/s", "/w/sx/a"), null);
  assert.equal(windows.paths.relativeIn("C:\\w\\s", "c:/W/S/a"), "a");
  assert.equal(windows.paths.relativeIn("C:\\w\\s", "C:\\w\\sx\\a"), null);
  assert.equal(windows.paths.relativeIn("C:\\w\\s", "D:\\w\\s\\a"), null);
  assert.ok(windows.paths.within(windows.paths.key("C:\\W\\S\\a"), windows.paths.key("c:\\w\\s")));
  assert.ok(!unix.paths.within("/w/sx", "/w/s"));
});

test("Windows' disks are its drives there, C: to Z:, by their letter", async () => {
  const asked: string[] = [];
  const there = await drives(async (path) => (asked.push(path), path === "C:\\" || path === "E:\\"));
  assert.deepEqual(there, [{ name: "C:", path: "C:\\" }, { name: "E:", path: "E:\\" }]);
  assert.equal(asked.length, 24);
  assert.ok(!asked.includes("A:\\") && !asked.includes("B:\\"));
});

test("a drive's path is a local link's on Windows only", () => {
  assert.ok(windows.paths.isDrivePath("C:\\Users\\a\\x.png") && windows.paths.isDrivePath("c:/x"));
  assert.ok(!unix.paths.isDrivePath("C:\\Users\\a\\x.png"));
  assert.ok(!windows.paths.isDrivePath("C:x"));
});

test("each machine names itself and its executables", () => {
  assert.equal(windows.os, "windows");
  assert.equal(windows.exe("stillfail-runner"), "stillfail-runner.exe");
  assert.equal(unix.exe("stillfail-runner"), "stillfail-runner");
  assert.equal(windows.home({ USERPROFILE: "C:\\Users\\a" }), "C:\\Users\\a");
  assert.equal(unix.home({ USERPROFILE: "C:\\Users\\a" }), undefined);
});

test("a .cmd names a path with other than ASCII in it through the variable it is under", () => {
  const env = { USERPROFILE: "C:\\Users\\张三", LOCALAPPDATA: "C:\\Users\\张三\\AppData\\Local", ProgramFiles: "C:\\Program Files" };
  assert.equal(cmdPath("C:\\Program Files\\Git\\bin\\sh.exe", env), "C:\\Program Files\\Git\\bin\\sh.exe");
  assert.equal(cmdPath("C:\\Users\\张三\\.stillfail\\app\\bin\\stillfail.cmd", env), "%USERPROFILE%\\.stillfail\\app\\bin\\stillfail.cmd");
  // The closest variable; its name in any case.
  assert.equal(cmdPath("c:\\users\\张三\\AppData\\Local\\Programs\\Git\\bin\\sh.exe", env), "%LOCALAPPDATA%\\Programs\\Git\\bin\\sh.exe");
  assert.equal(cmdPath("C:\\Users\\张三", env), "%USERPROFILE%");
  // Not one of its folders (张三x), or more than ASCII left: refused.
  assert.throws(() => cmdPath("C:\\Users\\张三x\\a", env), /cannot name/);
  assert.throws(() => cmdPath("C:\\Users\\张三\\数据\\a", env), /cannot name/);
  assert.throws(() => cmdPath("D:\\数据\\a", env), /cannot name/);
});

test("Windows' saved PATH is the machine's then the user's, each %VAR% expanded as a new process would have it", () => {
  const env = { USERPROFILE: "C:\\Users\\张三", SystemRoot: "C:\\WINDOWS", Path: "C:\\WINDOWS\\system32" };
  const machine = { Path: "%SystemRoot%\\system32;%SystemRoot%;C:\\Program Files\\Git\\cmd;;", ToolsRoot: "D:\\tools" };
  // A user variable is of the machine's too; one named by neither stays as written, as Windows leaves it.
  const user = { PATH: "%localappdata%\\agy\\bin;%ToolsRoot%\\bin;%NOPE%\\bin;relative\\bin;\\rooted;c:\\windows\\SYSTEM32", LOCALAPPDATA: "%USERPROFILE%\\AppData\\Local" };
  assert.deepEqual(savedPathOf(machine, user, env), [
    "C:\\WINDOWS\\system32",
    "C:\\WINDOWS",
    "C:\\Program Files\\Git\\cmd",
    "C:\\Users\\张三\\AppData\\Local\\agy\\bin",
    "D:\\tools\\bin",
  ]);
  assert.deepEqual(savedPathOf({}, {}, env), []);
});

test("what an npm or pnpm shim runs is run without cmd, which cannot pass a newline", () => {
  // As cmd-shim (npm's) and @zkochan/cmd-shim (pnpm's) write them (the runner's src/shim.rs reads the same).
  const npmJs =
    '@ECHO off\r\nGOTO start\r\n:find_dp0\r\nSET dp0=%~dp0\r\nEXIT /b\r\n:start\r\nSETLOCAL\r\nCALL :find_dp0\r\n\r\nIF EXIST "%dp0%\\node.exe" (\r\n  SET "_prog=%dp0%\\node.exe"\r\n) ELSE (\r\n  SET "_prog=node"\r\n  SET PATHEXT=%PATHEXT:;.JS;=;%\r\n)\r\n\r\nendLocal & goto #_undefined_# 2>NUL || title %COMSPEC% & "%_prog%"  "%dp0%\\node_modules\\said\\cli.js" %*\r\n';
  const npmExe = '@ECHO off\r\nGOTO start\r\n:find_dp0\r\nSET dp0=%~dp0\r\nEXIT /b\r\n:start\r\nSETLOCAL\r\nCALL :find_dp0\r\n"%dp0%\\node_modules\\@anthropic-ai\\claude-code\\bin\\claude.exe"   %*\r\n';
  const pnpmJs =
    '@SETLOCAL\r\n@IF EXIST "%~dp0\\node.exe" (\r\n  "%~dp0\\node.exe"  "%~dp0\\node_modules\\x\\bin\\cli.js" %*\r\n) ELSE (\r\n  @SET PATHEXT=%PATHEXT:;.JS;=;%\r\n  node  "%~dp0\\node_modules\\x\\bin\\cli.js" %*\r\n)\r\n';
  const pnpmExe = '@SETLOCAL\r\n@"%~dp0\\node_modules\\@anthropic-ai\\claude-code\\bin\\claude.exe"   %*\r\n';
  assert.deepEqual(readShim(npmJs), { node: { beside: "node_modules\\said\\cli.js" } });
  assert.deepEqual(readShim(pnpmJs), { node: { beside: "node_modules\\x\\bin\\cli.js" } });
  const claude = { program: { beside: "node_modules\\@anthropic-ai\\claude-code\\bin\\claude.exe" } };
  assert.deepEqual(readShim(npmExe), claude);
  assert.deepEqual(readShim(pnpmExe), claude);
  // Vite+'s hands on to another.
  assert.deepEqual(readShim('@echo off\r\n"C:\\Users\\a\\.vite-plus\\npm\\said.cmd" %*\r\nexit /b %ERRORLEVEL%\r\n'), {
    program: { at: "C:\\Users\\a\\.vite-plus\\npm\\said.cmd" },
  });
  // Anything else is cmd's: what the station writes for a script (Git's sh, through a variable) among them.
  for (const other of [
    "@echo said %*\r\n",
    '@echo off\r\nset X=1\r\n"%~dp0\\said.exe" %*\r\n',
    '@"%~dp0\\said.exe" --flag %*\r\n',
    '@"%USERPROFILE%\\Git\\bin\\sh.exe" "%~dp0said" %*\r\n',
    '@"%USERPROFILE%\\bin\\said.exe" %*\r\n',
  ])
    assert.equal(readShim(other), null, other);
});

test("a .cmd so written runs what is at such a path", { skip: process.platform !== "win32" && "cmd is Windows'" }, () => {
  const dir = mkdtempSync(join(tmpdir(), "cmd-path-"));
  try {
    const home = join(dir, "张三");
    mkdirSync(join(home, "bin"), { recursive: true });
    writeFileSync(join(home, "bin", "say.cmd"), "@echo said %*\r\n");
    const env = { ...process.env, USERPROFILE: home };
    writeFileSync(join(dir, "wrapper.cmd"), `@"${cmdPath(join(home, "bin", "say.cmd"), env)}" %*\r\n`);
    const ran = spawnSync(process.env.ComSpec ?? "cmd.exe", ["/d", "/c", join(dir, "wrapper.cmd"), "hi"], { env, encoding: "utf8" });
    assert.equal(ran.stdout.trim(), "said hi", ran.stderr);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

/// Files there, as Windows names them (case aside), for Git's sh found on any machine.
function windowsFiles(...paths: string[]) {
  const there = new Set(paths.map((p) => p.toLowerCase()));
  return { there, has: (p: string) => there.has(p.toLowerCase()), soon: async (p: string) => there.has(p.toLowerCase()) };
}

test("Windows' sh is Git's, found beside the git its installer put on PATH, never System32's", async () => {
  const git = "C:\\Program Files\\Git";
  const fs = windowsFiles(`${git}\\cmd\\git.exe`, `${git}\\bin\\sh.exe`, "C:\\Windows\\System32\\sh.exe", "D:\\own\\sh.exe", "C:\\Users\\a\\AppData\\Local\\Programs\\Git\\bin\\sh.exe");
  const none = async () => null;
  // Only Git's cmd\ on PATH (what its installer does): its bin\sh.exe.
  const onPath = { PATH: `C:\\Windows\\System32;${git}\\cmd` };
  assert.equal(gitShell(onPath, fs.has), `${git}\\bin\\sh.exe`);
  assert.equal(await gitShellSoon(onPath, none, fs.soon), `${git}\\bin\\sh.exe`);
  // Claude Code's own setting first.
  const set = { ...onPath, CLAUDE_CODE_GIT_BASH_PATH: "D:\\own\\sh.exe" };
  assert.equal(gitShell(set, fs.has), "D:\\own\\sh.exe");
  assert.equal(await gitShellSoon(set, none, fs.soon), "D:\\own\\sh.exe");
  // System32 (WSL's bash and the like) never; where Git installs by default.
  const system = { Path: "C:\\Windows\\System32\\", LOCALAPPDATA: "C:\\Users\\a\\AppData\\Local" };
  assert.equal(gitShell(system, fs.has), "C:\\Users\\a\\AppData\\Local\\Programs\\Git\\bin\\sh.exe");
  assert.equal(gitShell({ PATH: "C:\\Windows\\System32" }, fs.has), null);
  assert.equal(gitShell({ PATH: "C:\\Windows\\System32", ProgramFiles: "C:\\Program Files" }, fs.has), `${git}\\bin\\sh.exe`);
  assert.equal(await gitShellSoon({ PATH: "C:\\Windows\\System32", ProgramFiles: "C:\\Program Files" }, none, fs.soon), `${git}\\bin\\sh.exe`);
});

test("Windows' sh installed after the station started is found by the registry's PATH, and none found is never kept", async () => {
  const fs = windowsFiles();
  const env = { PATH: "C:\\Windows\\System32" };
  let saved: string[] | null = null;
  const readSaved = async () => saved;
  assert.equal(await gitShellSoon(env, readSaved, fs.soon), null);
  // Git put on D:\ meanwhile: the registry names its cmd\, which this process was never given.
  fs.there.add("d:\\git\\cmd\\git.exe");
  fs.there.add("d:\\git\\bin\\sh.exe");
  saved = ["C:\\Windows\\System32", "D:\\Git\\cmd"];
  assert.equal(await gitShellSoon(env, readSaved, fs.soon), "D:\\Git\\bin\\sh.exe");

  const later = windowsFiles();
  const shells = posixShells(later.has, async () => null, later.soon);
  const withRoot = { ...env, ProgramFiles: "C:\\Program Files" };
  await assert.rejects(shells.posixShellSoon(withRoot), /install Git for Windows \(git-scm\.com\), or set CLAUDE_CODE_GIT_BASH_PATH/);
  assert.throws(() => shells.posixShell(withRoot), /install Git for Windows/);
  later.there.add("c:\\program files\\git\\bin\\sh.exe");
  assert.equal(await shells.posixShellSoon(withRoot), "C:\\Program Files\\Git\\bin\\sh.exe");
  // Found once, kept for that environment: no file asked again.
  later.there.clear();
  assert.equal(shells.posixShell(withRoot), "C:\\Program Files\\Git\\bin\\sh.exe");
  assert.equal(await shells.posixShellSoon(withRoot), "C:\\Program Files\\Git\\bin\\sh.exe");
});

test("Windows' sh looked for off the station's thread waits on no file", async () => {
  const dir = mkdtempSync(join(tmpdir(), "git-shell-"));
  try {
    const env = { PATH: `C:\\Windows\\System32;${dir}`, ProgramFiles: dir, CLAUDE_CODE_GIT_BASH_PATH: join(dir, "nope.exe") };
    let found: string | null = "";
    assert.deepEqual(await syncCalls(async () => void (found = await gitShellSoon(env, async () => [dir]))), []);
    assert.equal(found, null);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("Monoid Machine station VM cmdline detection matches monoid.vm=station as a whole word", () => {
  const real = "memory_hotplug.memmap_on_memory=1 console=hvc0 lockdown=confidentiality monoid.vm=station systemd.hostname=station psi=1 loglevel=4";
  assert.equal(isMonoidStationVm(real), true);
  assert.equal(isMonoidStationVm("monoid.vm=apps"), false);
  assert.equal(isMonoidStationVm("xmonoid.vm=station"), false);
  assert.equal(isMonoidStationVm("monoid.vm=stationx"), false);
  assert.equal(isMonoidStationVm(""), false);
});

test("elasticMemory adds unplugged dom0 headroom and leaves invalid or unknown memory unchanged", () => {
  const T = 12681484 * 1024;
  const U = 4_000_000_000;
  const base = { totalBytes: T, usedBytes: U, swapUsedBytes: 0 };
  const pvg = { boot: 6576668672, guarantee: 11811160064, max: 26306674688, plugged: 6845104128, target: 6845104128 };
  assert.deepEqual(elasticMemory(base, pvg), { totalBytes: T + 12884901888, usedBytes: U, swapUsedBytes: 0 });
  // max <= held: unchanged.
  assert.deepEqual(elasticMemory(base, { boot: 1000, plugged: 500, max: 1500 }), base);
  assert.deepEqual(elasticMemory(base, { boot: 1000, plugged: 500, max: 1200 }), base);
  // Missing field, non-number, non-finite, null, or known: false: unchanged.
  assert.deepEqual(elasticMemory(base, { boot: 1000, plugged: 500 }), base);
  assert.deepEqual(elasticMemory(base, { boot: "1000", plugged: 500, max: 5000 }), base);
  assert.deepEqual(elasticMemory(base, { boot: 1000, plugged: 500, max: Number.POSITIVE_INFINITY }), base);
  assert.deepEqual(elasticMemory(base, null), base);
  const unknown = { totalBytes: T, usedBytes: 0, swapUsedBytes: null, known: false };
  assert.deepEqual(elasticMemory(unknown, pvg), unknown);
});

test("elasticMemoryReader skips fetch off a station VM and caches the last good answer for 60 s", async () => {
  let fetches = 0;
  const nonVm = elasticMemoryReader(
    async () => "console=hvc0 monoid.vm=apps",
    async () => { fetches++; return { boot: 1, plugged: 0, max: 10 }; },
    () => 1_000,
  );
  assert.equal(await nonVm(), null);
  assert.equal(await nonVm(), null);
  assert.equal(fetches, 0);

  const T = 12681484 * 1024;
  const U = 4_000_000_000;
  const base = { totalBytes: T, usedBytes: U, swapUsedBytes: null };
  const pvg = { boot: 6576668672, guarantee: 11811160064, max: 26306674688, plugged: 6845104128, target: 6845104128 };
  let clock = 10_000;
  let cmdlineReads = 0;
  let nextAnswer: () => Promise<unknown> = async () => pvg;
  const vm = elasticMemoryReader(
    async () => { cmdlineReads++; return "console=hvc0 monoid.vm=station psi=1"; },
    () => nextAnswer(),
    () => clock,
  );
  assert.deepEqual(elasticMemory(base, await vm()), { totalBytes: T + 12884901888, usedBytes: U, swapUsedBytes: null });
  // Failing fetch under 60 s keeps the last good answer.
  nextAnswer = async () => { throw new Error("timeout"); };
  clock = 10_000 + 59_999;
  assert.deepEqual(elasticMemory(base, await vm()), { totalBytes: T + 12884901888, usedBytes: U, swapUsedBytes: null });
  // At 60 s and after, falls back to plain meminfo.
  clock = 10_000 + 60_000;
  assert.deepEqual(elasticMemory(base, await vm()), base);
  assert.equal(cmdlineReads, 1);
});
