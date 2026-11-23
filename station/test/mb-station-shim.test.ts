// End-to-end tests for `stillfail-reader`'s lightweight `station_shim` (runs on both Unix and Windows):
// - retired whole-station commands (`run`, `status`, `id`, `admin`, legacy flag-only `--app`/`--port`)
// - `.mjs`/`.js` hooks and bare `claude-tui` alias
// - real `station/src/main.ts` boot via legacy `--app DIR --port 0 --data DIR` (verifying injected `run`)
// - Unix: in-place `execv` PID preservation, symlinked `<app>/station/stillfail-reader`, `OS=Windows_NT` immunity,
//   and `stillfail-reader-harness` self-delegation / wrapper-loop refusal
// - Windows: non-ASCII + astral emoji paths, special argument escaping, PATH fallback without CWD,
//   and Job Object (`KILL_ON_JOB_CLOSE | SILENT_BREAKAWAY_OK`) force-kill killing direct Node while
//   preserving detached grandchildren (stillfail-runner / background jobs).
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { chmodSync, copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { test, type TestContext } from "node:test";
import { mbReaderBinary } from "../src/read/mb-reader.ts";
import { mbHarnessBinary } from "./mb-harness.ts";

const reader = mbReaderBinary();
const harness = mbHarnessBinary();
const isWin = process.platform === "win32";
const skip = reader === null ? "stillfail-reader is not built here" : false;
const skipUnix = skip || (isWin ? "Unix-specific test" : false);
const skipWin = skip || (!isWin ? "Windows-specific test" : false);
const mainTs = fileURLToPath(new URL("../src/main.ts", import.meta.url));

const reportScript = (who: string) => `
process.stdout.write(JSON.stringify({
  who: ${JSON.stringify(who)},
  pid: process.pid,
  argv: process.argv.slice(2),
}) + "\\n");
process.exit(Number(process.env.FAKE_EXIT ?? "0"));
`;

function readerFilename(): string {
  return isWin ? "stillfail-reader.exe" : "stillfail-reader";
}

function baseEnv(extra: Record<string, string> = {}): Record<string, string> {
  if (isWin) {
    // Keep essential Windows system variables (SystemRoot, TEMP, etc.) while clearing PATH and STILLFAIL_*.
    const keep: Record<string, string> = {};
    for (const [k, v] of Object.entries(process.env)) {
      if (v === undefined) continue;
      if (/^(SystemRoot|SystemDrive|WINDIR|TEMP|TMP|COMSPEC|USERPROFILE)$/i.test(k)) keep[k] = v;
    }
    return { ...keep, PATH: "", ...extra };
  }
  return { PATH: "", ...extra };
}

function makeApp(
  t: TestContext,
  opts: {
    mainJs?: boolean;
    adminJs?: boolean;
    adminTs?: boolean;
    claudeTui?: boolean;
    bundledNode?: boolean;
    appName?: string;
  } = {},
) {
  const base = mkdtempSync(join(tmpdir(), "sf-shim-"));
  t.after(() => rmSync(base, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 }));
  const app = join(base, opts.appName ?? "app");
  mkdirSync(join(app, "station"), { recursive: true });
  const bin = join(app, "station", readerFilename());
  copyFileSync(reader!, bin);
  if (!isWin) chmodSync(bin, 0o755);
  if (opts.mainJs) writeFileSync(join(app, "station", "main.js"), reportScript("main.js"));
  if (opts.adminJs) writeFileSync(join(app, "station", "admin-cli.js"), reportScript("admin-cli.js"));
  if (opts.adminTs) {
    mkdirSync(join(app, "bin"), { recursive: true });
    writeFileSync(join(app, "bin", "admin-cli.ts"), `const x: string = "ts"; void x;\n${reportScript("admin-cli.ts")}`);
  }
  if (opts.claudeTui) writeFileSync(join(app, "station", "claude-tui.mjs"), reportScript("claude-tui.mjs"));
  if (opts.bundledNode) {
    if (isWin) {
      mkdirSync(join(app, "node"), { recursive: true });
      copyFileSync(process.execPath, join(app, "node", "node.exe"));
    } else {
      mkdirSync(join(app, "node", "bin"), { recursive: true });
      symlinkSync(process.execPath, join(app, "node", "bin", "node"));
    }
  }
  return { base, app, bin };
}

function runWithPid(
  file: string,
  args: string[],
  env: Record<string, string>,
  cwd?: string,
): Promise<{ pid: number; code: number | null; stdout: string; stderr: string }> {
  return new Promise((resolve, reject) => {
    const child = spawn(file, args, { env, cwd, stdio: ["ignore", "pipe", "pipe"] });
    const pid = child.pid!;
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (d) => (stdout += d));
    child.stderr.on("data", (d) => (stderr += d));
    child.on("error", reject);
    child.on("close", (code) => resolve({ pid, code, stdout, stderr }));
  });
}

function pidAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

test("station_shim hands off whole-station commands and injects 'run' (and --app) for legacy flag-only invocations", { skip }, async (t) => {
  const { app, bin } = makeApp(t, { mainJs: true, bundledNode: true });
  const r = await runWithPid(bin, ["status", "--data", "/tmp/d1"], baseEnv({ FAKE_EXIT: "7" }));
  assert.equal(r.code, 7, r.stderr);
  const out = JSON.parse(r.stdout.trim());
  assert.equal(out.who, "main.js");
  if (!isWin) assert.equal(out.pid, r.pid, "must execv in place preserving PID on Unix");
  assert.deepEqual(out.argv, ["status", "--data", "/tmp/d1"]);
  assert.match(r.stderr, /"engine": "moonbit" is retired/);

  // Legacy flag-only with --app and --port: must inject "run"
  const r2 = await runWithPid(bin, ["--app", app, "--port", "4760"], baseEnv());
  assert.equal(r2.code, 0, r2.stderr);
  const out2 = JSON.parse(r2.stdout.trim());
  assert.equal(out2.who, "main.js");
  if (!isWin) assert.equal(out2.pid, r2.pid);
  assert.deepEqual(out2.argv, ["run", "--app", app, "--port", "4760"]);

  // Legacy flag-only with --port only (no --app): must inject "run", "--app", <app>
  const r3 = await runWithPid(bin, ["--port", "4760", "--data", "/tmp/d3"], baseEnv());
  assert.equal(r3.code, 0, r3.stderr);
  const out3 = JSON.parse(r3.stdout.trim());
  assert.equal(out3.who, "main.js");
  assert.deepEqual(out3.argv, ["run", "--app", app, "--port", "4760", "--data", "/tmp/d3"]);
});

test("station_shim legacy flag-only `--app DIR --port 0 --data DIR` boots real station/src/main.ts instead of exiting 2", { skip: skipUnix, timeout: 60_000 }, async (t) => {
  const { base, app, bin } = makeApp(t, { bundledNode: true });
  writeFileSync(join(app, "BUILD"), "9700\n");
  writeFileSync(join(app, "station", "main.js"), `import ${JSON.stringify(pathToFileURL(mainTs).href)};\n`);
  const data = join(base, "data");
  mkdirSync(data, { recursive: true });
  const env = baseEnv({
    HOME: data,
    TMPDIR: tmpdir(),
    STILLFAIL_NO_DISCOVERY: "1",
    STILLFAIL_MB_READER: bin,
    ...(process.env.STILLFAIL_MESH_NATIVE ? { STILLFAIL_MESH_NATIVE: process.env.STILLFAIL_MESH_NATIVE } : {}),
    ...(process.env.STILLFAIL_RUNNER ? { STILLFAIL_RUNNER: process.env.STILLFAIL_RUNNER } : {}),
  });
  const child = spawn(bin, ["--app", app, "--port", "0", "--data", data], { env, stdio: ["ignore", "pipe", "pipe"] });
  let stderr = "";
  child.stderr.on("data", (d) => (stderr += d));
  t.after(() => {
    if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
  });
  const ended = new Promise<number | null>((resolve) => child.on("exit", (code) => resolve(code)));
  const deadline = Date.now() + 25_000;
  while (Date.now() < deadline) {
    if (child.exitCode !== null) {
      assert.fail(`real main.ts exited early with code ${child.exitCode}: ${stderr}`);
    }
    if (existsSync(join(data, "run", "mcp.json"))) break;
    await new Promise((r) => setTimeout(r, 50));
  }
  assert.ok(existsSync(join(data, "run", "mcp.json")), `real main.ts did not reach running state: ${stderr}`);
  assert.doesNotMatch(stderr, /usage:/i);
  child.kill("SIGTERM");
  assert.equal(await ended, 0, stderr);
});

test("station_shim hands off admin (without --app) to station/admin-cli.js or dev bin/admin-cli.ts stripping 'admin'", { skip }, async (t) => {
  const rel = makeApp(t, { adminJs: true, bundledNode: true });
  const r1 = await runWithPid(rel.bin, ["admin", "--data", "/tmp/d2", "whoami", "--json"], baseEnv());
  assert.equal(r1.code, 0, r1.stderr);
  const out1 = JSON.parse(r1.stdout.trim());
  assert.equal(out1.who, "admin-cli.js");
  if (!isWin) assert.equal(out1.pid, r1.pid);
  assert.deepEqual(out1.argv, ["--data", "/tmp/d2", "whoami", "--json"]);

  const dev = makeApp(t, { adminTs: true, bundledNode: true });
  const r2 = await runWithPid(dev.bin, ["admin", "users", "list"], baseEnv());
  assert.equal(r2.code, 0, r2.stderr);
  const out2 = JSON.parse(r2.stdout.trim());
  assert.equal(out2.who, "admin-cli.ts");
  if (!isWin) assert.equal(out2.pid, r2.pid);
  assert.deepEqual(out2.argv, ["users", "list"]);
});

test("station_shim runs .mjs/.js hook scripts, bare claude-tui alias, and respects STILLFAIL_NODE > app/node > PATH", { skip }, async (t) => {
  const { base, bin } = makeApp(t, { mainJs: true, claudeTui: true });
  const hook = join(base, "repo-rules-hook.mjs");
  writeFileSync(hook, reportScript("hook.mjs"));

  // Found via STILLFAIL_NODE
  const r1 = await runWithPid(bin, [hook, "arg1", "arg2"], baseEnv({ STILLFAIL_NODE: process.execPath }));
  assert.equal(r1.code, 0, r1.stderr);
  const out1 = JSON.parse(r1.stdout.trim());
  assert.equal(out1.who, "hook.mjs");
  if (!isWin) assert.equal(out1.pid, r1.pid);
  assert.deepEqual(out1.argv, ["arg1", "arg2"]);

  // Bare `claude-tui` alias maps to `<app>/station/claude-tui.mjs`
  const rTui = await runWithPid(bin, ["claude-tui", "hook", "--extra"], baseEnv({ STILLFAIL_NODE: process.execPath }));
  assert.equal(rTui.code, 0, rTui.stderr);
  const outTui = JSON.parse(rTui.stdout.trim());
  assert.equal(outTui.who, "claude-tui.mjs");
  assert.deepEqual(outTui.argv, ["hook", "--extra"]);

  // Found via PATH when STILLFAIL_NODE is unset and no bundled node
  const pathDir = join(base, "pathbin");
  mkdirSync(pathDir);
  if (isWin) copyFileSync(process.execPath, join(pathDir, "node.exe"));
  else symlinkSync(process.execPath, join(pathDir, "node"));
  const r2 = await runWithPid(bin, [hook, "via-path"], baseEnv({ PATH: pathDir }));
  assert.equal(r2.code, 0, r2.stderr);
  assert.deepEqual(JSON.parse(r2.stdout.trim()).argv, ["via-path"]);
});

test("station_shim preserves non-ASCII + astral emoji paths and tricky special arguments across Unix & Windows", { skip }, async (t) => {
  const { app, bin } = makeApp(t, {
    adminJs: true,
    bundledNode: true,
    appName: "测试 🚀 app dir",
  });
  const tricky = ["pre", "", "post", 'a"b', 'say "hi there"', "C:\\dir with space\\", 'back\\\\"slash', "a\\\n", "--json"];
  const r = await runWithPid(bin, ["admin", ...tricky], baseEnv());
  assert.equal(r.code, 0, `app=${app}\nstderr=${r.stderr}`);
  const out = JSON.parse(r.stdout.trim());
  assert.equal(out.who, "admin-cli.js");
  assert.deepEqual(out.argv, tricky);
});

test("station_shim fails loudly with non-zero exit when Node or entry script is missing", { skip }, (t) => {
  const noNode = makeApp(t, { mainJs: true });
  const r1 = spawnSync(noNode.bin, ["status"], { env: baseEnv(), encoding: "utf8" });
  assert.notEqual(r1.status, 0);
  assert.match(r1.stderr, /no Node executable was found/);

  const noScript = makeApp(t, { bundledNode: true });
  const r2 = spawnSync(noScript.bin, ["run", "--app", noScript.app], { env: baseEnv(), encoding: "utf8" });
  assert.notEqual(r2.status, 0);
  assert.match(r2.stderr, /station\/main\.js was not found/);
});

test("Unix: symlinked <app>/station/stillfail-reader resolves bundled node & main.js under symlink's app dir, and OS=Windows_NT does not confuse host detection", { skip: skipUnix }, async (t) => {
  const base = mkdtempSync(join(tmpdir(), "sf-shim-sym-"));
  t.after(() => rmSync(base, { recursive: true, force: true }));
  // Actual binary stored outside <app> (e.g. shared native cache)
  const cacheBin = join(base, "cache", "stillfail-reader");
  mkdirSync(dirname(cacheBin), { recursive: true });
  copyFileSync(reader!, cacheBin);
  chmodSync(cacheBin, 0o755);

  const app = join(base, "release-app");
  mkdirSync(join(app, "station"), { recursive: true });
  mkdirSync(join(app, "node", "bin"), { recursive: true });
  symlinkSync(process.execPath, join(app, "node", "bin", "node"));
  writeFileSync(join(app, "station", "main.js"), reportScript("symlink-main.js"));
  writeFileSync(join(app, "station", "admin-cli.js"), reportScript("symlink-admin.js"));
  const linkBin = join(app, "station", "stillfail-reader");
  symlinkSync(cacheBin, linkBin);

  // Even with OS=Windows_NT set in env on Unix, compile-time sfh_is_windows() keeps Unix path & node lookup
  const r = await runWithPid(linkBin, ["status", "--data", "/tmp/d"], baseEnv({ OS: "Windows_NT" }));
  assert.equal(r.code, 0, r.stderr);
  const out = JSON.parse(r.stdout.trim());
  assert.equal(out.who, "symlink-main.js");
  assert.equal(out.pid, r.pid);
  assert.deepEqual(out.argv, ["status", "--data", "/tmp/d"]);

  // Symlinked <app>/station/stillfail-reader with empty PATH and bundled Node works across all 4 invocation forms:
  // 1) cwd=app: `station/stillfail-reader`
  // 2) cwd=app/station: `./stillfail-reader`
  // 3) cwd=app/station/sub: `../stillfail-reader`
  // 4) cwd=app/station: absolute symlink path
  const subDir = join(app, "station", "sub");
  mkdirSync(subDir, { recursive: true });
  for (const [cmd, cwd] of [
    ["station/stillfail-reader", app],
    ["./stillfail-reader", join(app, "station")],
    ["../stillfail-reader", subDir],
    [linkBin, join(app, "station")],
  ] as const) {
    const rSym = await runWithPid(cmd, ["admin", "--help"], baseEnv(), cwd);
    assert.equal(rSym.code, 0, `${cmd} in ${cwd}: ${rSym.stderr}`);
    const outSym = JSON.parse(rSym.stdout.trim());
    assert.equal(outSym.who, "symlink-admin.js", `${cmd} in ${cwd}`);
    assert.equal(outSym.pid, rSym.pid);
    assert.deepEqual(outSym.argv, ["--help"]);
  }

  // POSIX PATH semantics on Unix: trailing empty segment in non-empty PATH searches CWD (`.`)
  const pathApp = makeApp(t, { mainJs: true });
  const cwdBin = join(pathApp.base, "cwd-node");
  mkdirSync(cwdBin, { recursive: true });
  symlinkSync(process.execPath, join(cwdBin, "node"));
  const rPosix = await runWithPid(pathApp.bin, ["status"], baseEnv({ PATH: "/nonexistent-stillfail-dir:" }), cwdBin);
  assert.equal(rPosix.code, 0, rPosix.stderr);
  assert.equal(JSON.parse(rPosix.stdout.trim()).who, "main.js");
});

test("Unix: stillfail-reader-harness refuses self-delegation and wrapper delegation loops instead of recursing forever", { skip: skipUnix || (harness === null ? "stillfail-reader-harness is not built here" : false) }, (t) => {
  // 1. Direct self-reference: STILLFAIL_MB_READER points to harness itself
  const selfRes = spawnSync(harness!, ["--builder", "footprint"], {
    env: baseEnv({ STILLFAIL_MB_READER: harness! }),
    encoding: "utf8",
    timeout: 10_000,
  });
  assert.equal(selfRes.status, 1);
  assert.match(selfRes.stderr, /points to stillfail-reader-harness itself|refusing recursive exec/);

  // 2. Wrapper loop: STILLFAIL_MB_READER points to a script that execs harness back
  const base = mkdtempSync(join(tmpdir(), "sf-harness-loop-"));
  t.after(() => rmSync(base, { recursive: true, force: true }));
  const wrapper = join(base, "loop.sh");
  const q = (s: string) => `'${s.replaceAll("'", "'\\''")}'`;
  writeFileSync(wrapper, `#!/bin/sh\nexec ${q(harness!)} "$@"\n`, { mode: 0o755 });
  const loopRes = spawnSync(harness!, ["--builder", "footprint"], {
    env: baseEnv({ STILLFAIL_MB_READER: wrapper }),
    encoding: "utf8",
    timeout: 10_000,
  });
  assert.equal(loopRes.status, 1);
  assert.match(loopRes.stderr, /delegation loop detected|STILLFAIL_HARNESS_DELEGATED=1/);
});

test("Windows: PATH fallback ignores CWD node.exe, and Job Object kills direct Node on shim force-kill while detached grandchild survives", { skip: skipWin, timeout: 60_000 }, async (t) => {
  // 1. PATH fallback must not execute a decoy node.exe sitting in CWD when PATH is empty
  const decoy = makeApp(t, { mainJs: true });
  const cwdDir = join(decoy.base, "cwd-decoy");
  mkdirSync(cwdDir, { recursive: true });
  copyFileSync(process.execPath, join(cwdDir, "node.exe"));
  const rDecoy = await runWithPid(decoy.bin, ["status"], baseEnv(), cwdDir);
  assert.notEqual(rDecoy.code, 0, "CWD node.exe must not be executed via PATH fallback");
  assert.match(rDecoy.stderr, /no Node executable was found/);

  // 2. Job Object test: force-killing shim terminates direct Node child, while detached grandchild survives
  const { base, app, bin } = makeApp(t, { bundledNode: true });
  const pidFile = join(base, "pids.json");
  writeFileSync(
    join(app, "station", "main.js"),
    `
const { spawn } = require("node:child_process");
const { writeFileSync } = require("node:fs");
const grand = spawn(process.execPath, ["-e", "setInterval(() => {}, 1000);"], {
  detached: true,
  stdio: "ignore",
});
grand.unref();
writeFileSync(${JSON.stringify(pidFile)}, JSON.stringify({ nodePid: process.pid, grandPid: grand.pid }));
setInterval(() => {}, 1000);
`,
  );

  let grandPid = 0;
  let nodePid = 0;
  const shim = spawn(bin, ["run", "--app", app], { env: baseEnv(), stdio: ["ignore", "pipe", "pipe"] });
  let shimErr = "";
  shim.stderr.on("data", (d) => (shimErr += d));
  t.after(() => {
    try { if (shim.exitCode === null) shim.kill("SIGKILL"); } catch {}
    try { if (nodePid > 0) process.kill(nodePid, "SIGKILL"); } catch {}
    try { if (grandPid > 0) process.kill(grandPid, "SIGKILL"); } catch {}
  });

  const deadline = Date.now() + 20_000;
  while (Date.now() < deadline && !existsSync(pidFile)) {
    assert.equal(shim.exitCode, null, `shim exited early: ${shimErr}`);
    await new Promise((r) => setTimeout(r, 50));
  }
  assert.ok(existsSync(pidFile), `fake Node never wrote pidFile: ${shimErr}`);
  const pids = JSON.parse(readFileSync(pidFile, "utf8")) as { nodePid: number; grandPid: number };
  nodePid = pids.nodePid;
  grandPid = pids.grandPid;
  assert.ok(pidAlive(nodePid), "direct Node child must be alive before force-kill");
  assert.ok(pidAlive(grandPid), "detached grandchild must be alive before force-kill");

  // Force-kill shim (simulating old Windows launcher TerminateProcess)
  const shimExited = new Promise<void>((resolve) => shim.once("exit", () => resolve()));
  shim.kill();
  await shimExited;

  // Direct Node child must terminate promptly via JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
  const killDeadline = Date.now() + 10_000;
  while (Date.now() < killDeadline && pidAlive(nodePid)) {
    await new Promise((r) => setTimeout(r, 50));
  }
  assert.equal(pidAlive(nodePid), false, `direct Node child (pid ${nodePid}) survived shim force-kill`);

  // Detached grandchild must survive via JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK
  assert.equal(pidAlive(grandPid), true, `detached grandchild (pid ${grandPid}) died when shim was force-killed`);

  // Terminate the detached grandchild and wait for Windows to release the executable handle before t.after rmSync runs.
  try { process.kill(grandPid, "SIGKILL"); } catch {}
  const grandDead = Date.now() + 5_000;
  while (Date.now() < grandDead && pidAlive(grandPid)) {
    await new Promise((r) => setTimeout(r, 50));
  }
  assert.equal(pidAlive(grandPid), false, `detached grandchild (pid ${grandPid}) did not exit after cleanup kill`);
});
