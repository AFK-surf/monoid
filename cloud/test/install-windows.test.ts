import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { bundledWindowsInstallScript, windowsInstallScript } from "../src/install-windows.ts";

/** PowerShell here, if any: Windows' own, or pwsh (STILLFAIL_PWSH names one elsewhere). */
const powershell = [process.env.STILLFAIL_PWSH, "powershell", "pwsh"].find((p) => p && spawnSync(p, ["-NoProfile", "-Command", "exit 0"]).status === 0);

test("the Windows installer has every placeholder filled, in both languages and channels", () => {
  for (const lang of ["zh", "en"] as const) {
    for (const channel of ["stable", "beta"] as const) {
      const script = windowsInstallScript("https://ember.test", channel, lang);
      assert.doesNotMatch(script, /__[A-Z]+_*/);
      assert.match(script, new RegExp(`\\$channel = if \\(\\$env:STILLFAIL_CHANNEL\\) \\{ \\$env:STILLFAIL_CHANNEL \\} else \\{ '${channel}' \\}`));
    }
  }
  // A message with values is PowerShell's -f over them, its quotes doubled.
  assert.match(windowsInstallScript("https://ember.test", "stable", "en"), /\('[^']*\{0\}[^']*' -f \$nodeVersion\)/);
});

test("the installer a Windows release carries is the cloud's, its cloud the one the station names", () => {
  for (const lang of ["zh", "en"] as const) {
    const script = bundledWindowsInstallScript(lang);
    assert.ok(script.startsWith(String.fromCharCode(0xfeff)), "with a BOM");
    assert.doesNotMatch(script, /__[A-Z]+_*/);
    assert.match(script, /^\$origin = \$env:STILLFAIL_ORIGIN\nif \(-not \$origin\) \{/m);
    assert.match(script, new RegExp(`\\$lang = if \\(\\$env:STILLFAIL_INSTALL_LANG\\) \\{ \\$env:STILLFAIL_INSTALL_LANG \\} else \\{ '${lang}' \\}`));
  }
  const script = windowsInstallScript("https://ember.test");
  // The release's hash, when the station gives it, checked before it is opened; its own installer handed it, once.
  assert.match(script, /if \(\$env:STILLFAIL_RELEASE_SHA256 -and \(Get-FileHash -Algorithm SHA256 \$zip\)\.Hash -ne \$env:STILLFAIL_RELEASE_SHA256\) \{ Fail/);
  assert.ok(script.indexOf("STILLFAIL_RELEASE_SHA256 -and (Get-FileHash") < script.indexOf("Expand-Archive -Path $zip"));
  assert.ok(script.includes("-match '[\\\\/]stillfail-handed-[0-9a-f]+[\\\\/]stillfail\\.zip$'"));
  assert.match(script, /if \(\$env:STILLFAIL_RELEASE_SHA256 -and -not \$env:STILLFAIL_INSTALLER_HANDED -and \(Test-Path -LiteralPath \$itsOwn\)\)/);
  // node.exe checked by its signed hash when there is one.
  assert.match(script, /if \(\$signedNode -and \(Get-FileHash -Algorithm SHA256 \(Join-Path \$part 'node\.exe'\)\)\.Hash -ne \$signedNode\) \{ Fail/);
});

test("the station's logon task runs elevated only when -Admin is asked for, and keeps it over updates", () => {
  const script = windowsInstallScript("https://ember.test");
  // Opt-in: the -Admin switch, STILLFAIL_ADMIN, or a windows.json that kept admin.
  assert.match(script, /param\(\[string\]\$Token = '', \[string\]\$Lock = '', \[string\]\$Rig = '', \[switch\]\$Admin\)/);
  assert.match(script, /\$adminRun = \$Admin -or \(\$apart\.admin -eq \$true\) -or \(\$env:STILLFAIL_ADMIN -eq '1'\)/);
  assert.match(script, /\$runLevel = if \(\$adminRun\) \{ 'Highest' \} else \{ 'Limited' \}/);
  // The one place the run level is set is the parameter, never a hard-coded Limited/Highest.
  assert.match(script, /-LogonType Interactive -RunLevel \$runLevel\b/);
  assert.doesNotMatch(script, /-RunLevel (Highest|Limited)\b/);
  // Kept in windows.json so the station's own updates stay elevated, and carried over the release handoff.
  assert.match(script, /if \(\$adminRun\) \{ \$kept\.admin = \$true \}/);
  assert.match(script, /if \(\$adminRun\) \{ \$env:STILLFAIL_ADMIN = '1' \}/);
});

test("the Windows installer keeps its state in its own scope", () => {
  // It runs as a script block (`& ([scriptblock]::Create(...))`): $script: and $global: there are its caller's, so a
  // function setting one leaves the installer's variable as it was.
  assert.deepEqual(windowsInstallScript("https://ember.test").match(/\$(script|global):\w+/gi) ?? [], []);
});

test("what the installer and the uninstaller stop is every program a Windows release runs from its directory, the Pion reader too", () => {
  // `$ours`: the processes of the release, by name, ended before its files are replaced or taken away; one left running
  // holds its .exe open, and the swap or the removal fails.
  const names = (script: string) => [...script.match(/\$ours = \{[^\n]*-and \$_\.Name -in ([^}]*) \}/)![1].matchAll(/'([^']+)'/g)].map((m) => m[1]);
  const installer = names(windowsInstallScript("https://ember.test"));
  assert.deepEqual(installer, ["node.exe", "stillfail-station.exe", "stillfail-station-w.exe", "stillfail-reader.exe", "stillfail-pion.exe"]);
  // bin/stillfail.ps1's `uninstall` stops the same (apps/mbui/src/host/station_uninstall.h carries it word for word,
  // apps/mbui/scripts/station_uninstall_test.c holds them the same).
  assert.deepEqual(names(readFileSync(new URL("../../bin/stillfail.ps1", import.meta.url), "utf8")), installer);
});

test("the stillfail command the installer writes runs the release under a home with other than ASCII in its path", { skip: (spawnSync("powershell", ["-NoProfile", "-Command", "exit 0"]).status !== 0 || spawnSync("cmd", ["/d", "/c", "exit 0"]).status !== 0) && "no PowerShell and cmd" }, () => {
  const dir = mkdtempSync(join(tmpdir(), "install-cmd-"));
  try {
    const home = join(dir, "张三");
    const release = join(home, ".stillfail", "app", "bin");
    mkdirSync(release, { recursive: true });
    writeFileSync(join(release, "stillfail.cmd"), "@echo the release's stillfail %*\r\n");
    // The installer's own functions, as it has them, with its Fail.
    const script = windowsInstallScript("https://ember.test");
    const fn = (name: string) => script.match(new RegExp(`^function ${name}\\(.*?^}$`, "ms"))![0];
    const file = join(dir, "write.ps1");
    writeFileSync(file, "﻿" + ["function Fail([string]$t) { throw $t }", fn("CmdPath"), fn("WriteCmd"),
      `WriteCmd (Join-Path $env:TEST_DIR 'stillfail.cmd') (Join-Path $env:USERPROFILE '.stillfail\\app\\bin\\stillfail.cmd')`].join("\n"));
    const env = { ...process.env, USERPROFILE: home, TEST_DIR: dir };
    const wrote = spawnSync("powershell", ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", file], { env, encoding: "utf8" });
    assert.equal(wrote.status, 0, wrote.stdout + wrote.stderr);
    assert.equal(readFileSync(join(dir, "stillfail.cmd"), "utf8").trim(), '@"%USERPROFILE%\\.stillfail\\app\\bin\\stillfail.cmd" %*');
    const ran = spawnSync("cmd", ["/d", "/c", join(dir, "stillfail.cmd"), "status"], { env, encoding: "utf8" });
    assert.equal(ran.stdout.trim(), "the release's stillfail status", ran.stderr);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("another product's command sets its own data directory only where none is set, named as its release is", () => {
  const fn = windowsInstallScript("https://app.monoid.build").match(/^function WriteCmd\(.*?^}$/ms)![0];
  // As bin/stillfail's ${STILLFAIL_DATA:-...}: one the caller set is kept.
  assert.match(fn, /'@if not defined STILLFAIL_DATA set "STILLFAIL_DATA=' \+ \$dir \+ '"'/);
  assert.doesNotMatch(fn, /'@set "STILLFAIL_DATA=/);
  // The data directory through the variable it is under too, so a home with other than ASCII in its path does not
  // send another product's command to the code page still.fail's never needs.
  assert.match(fn, /\$namedData = if \(\$product -ne 'stillfail'\) \{ CmdPath \$data \}/);
  assert.match(fn, /if \(\$named -and \$null -ne \$namedData\) \{ Set-Content -Path \$file -Encoding ASCII /);
});

test("another product's command the installer writes runs its release on its own data under a home no code page can say", { skip: !powershell && "no PowerShell" }, () => {
  const dir = mkdtempSync(join(tmpdir(), "install-cmd-"));
  try {
    // (an emoji: in no OEM code page, so the file is ASCII or refused whatever the system's)
    const home = join(dir, "张😀");
    const release = join(home, ".monoid", "app", "bin");
    mkdirSync(release, { recursive: true });
    writeFileSync(join(release, "stillfail.cmd"), '@if "%STILLFAIL_DATA%"=="%USERPROFILE%\\.monoid" (echo own data %*) else (echo data %STILLFAIL_DATA% %*)\r\n');
    const script = windowsInstallScript("https://app.monoid.build");
    const fn = (name: string) => script.match(new RegExp(`^function ${name}\\(.*?^}$`, "ms"))![0];
    const file = join(dir, "write.ps1");
    // (the paths as Windows has them, joined by hand so that PowerShell elsewhere joins them the same)
    writeFileSync(file, "﻿" + ["function Fail([string]$t) { throw $t }", "$product = 'monoid'", "$data = $env:USERPROFILE + '\\.monoid'", fn("CmdPath"), fn("WriteCmd"),
      `WriteCmd (Join-Path $env:TEST_DIR 'monoid.cmd') ($env:USERPROFILE + '\\.monoid\\app\\bin\\stillfail.cmd')`].join("\n"));
    const env: NodeJS.ProcessEnv = { ...process.env, USERPROFILE: home, TEST_DIR: dir };
    delete env.STILLFAIL_DATA;
    const wrote = spawnSync(powershell!, ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", file], { env, encoding: "utf8" });
    assert.equal(wrote.status, 0, wrote.stdout + wrote.stderr);
    const written = readFileSync(join(dir, "monoid.cmd"));
    assert.ok(written.every((b) => b < 0x80), "ASCII");
    assert.deepEqual(written.toString("ascii").trim().split(/\r?\n/), ["@setlocal", '@if not defined STILLFAIL_DATA set "STILLFAIL_DATA=%USERPROFILE%\\.monoid"', '@"%USERPROFILE%\\.monoid\\app\\bin\\stillfail.cmd" %*']);
    // What uninstalling takes for its command (bin/stillfail.ps1).
    assert.ok(written.toString("ascii").includes("%USERPROFILE%\\.monoid\\app"));
    if (spawnSync("cmd", ["/d", "/c", "exit 0"]).status !== 0) return; // (run only where there is cmd)
    const ran = spawnSync("cmd", ["/d", "/c", join(dir, "monoid.cmd"), "status"], { env, encoding: "utf8" });
    assert.equal(ran.stdout.trim(), "own data status", ran.stderr);
    const told = spawnSync("cmd", ["/d", "/c", join(dir, "monoid.cmd"), "status"], { env: { ...env, STILLFAIL_DATA: "C:\\elsewhere" }, encoding: "utf8" });
    assert.equal(told.stdout.trim(), "data C:\\elsewhere status", told.stderr);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("the Windows installer is one PowerShell parses", { skip: spawnSync("powershell", ["-NoProfile", "-Command", "exit 0"]).status !== 0 && "no PowerShell" }, () => {
  const dir = mkdtempSync(join(tmpdir(), "install-ps1-"));
  try {
    for (const lang of ["zh", "en"] as const) {
      const file = join(dir, `install-${lang}.ps1`);
      // With a BOM, as PowerShell 5.1 reads a file of non-ASCII words.
      writeFileSync(file, "﻿" + windowsInstallScript("https://it's.ember.test", "stable", lang));
      const parsed = spawnSync("powershell", ["-NoProfile", "-Command",
        `$e = $null; [void][System.Management.Automation.Language.Parser]::ParseFile('${file.replaceAll("'", "''")}', [ref]$null, [ref]$e); $e | ForEach-Object { "$($_.Extent.StartLineNumber): $($_.Message)" }`,
      ], { encoding: "utf8" });
      assert.equal(parsed.status, 0, parsed.stderr);
      assert.equal(parsed.stdout.trim(), "", `${lang}: ${parsed.stdout}`);
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("the Windows installer reports the new process's handover reason, falling back to the launcher", { skip: !powershell && "no PowerShell" }, () => {
  const dir = mkdtempSync(join(tmpdir(), "handoff-why-"));
  try {
    const script = windowsInstallScript("https://ember.test", "stable", "en");
    const fn = script.match(/^function HandoffWhy \{.*?^\}/ms)?.[0];
    assert.ok(fn);
    const file = join(dir, "why.ps1");
    writeFileSync(file, "\ufeff" + `$run = $env:TEST_DIR\n${fn}\nHandoffWhy\n`);
    const why = () => {
      const result = spawnSync(powershell!, ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", file], {
        env: { ...process.env, TEST_DIR: dir }, encoding: "utf8",
      });
      assert.equal(result.status, 0, result.stderr);
      return result.stdout.trim();
    };
    writeFileSync(join(dir, "handoff-failed"), "the new station exited with 1\n");
    assert.equal(why(), "the new station exited with 1");
    writeFileSync(join(dir, "handoff-error"), "Cannot read config: encrypted or damaged\n");
    assert.equal(why(), "Cannot read config: encrypted or damaged");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("a Windows station updating itself installs only the release its signed words name, by that release's own installer", { skip: !powershell && "no PowerShell" }, async () => {
  const dir = mkdtempSync(join(tmpdir(), "install-signed-"));
  const { createHash } = await import("node:crypto");
  const { execFile, execFileSync } = await import("node:child_process");
  const { createServer } = await import("node:http");
  const server = createServer((req, res) => {
    if (req.url === "/releases/stillfail-station-win32-x64.zip") return void res.end(readFileSync(join(dir, "release.zip")));
    res.writeHead(404).end();
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  try {
    // The release, carrying its installer: here one that says it ran, handed the download.
    const release = join(dir, "release", "stillfail", "bin");
    mkdirSync(release, { recursive: true });
    writeFileSync(join(release, "install.en.ps1"), "Set-Content -Path (Join-Path $env:STILLFAIL_DATA 'handed') -Value ('handed ' + $env:STILLFAIL_INSTALLER_HANDED + ' ' + (Test-Path -LiteralPath $env:STILLFAIL_ARCHIVE))\nexit 0\n");
    execFileSync("zip", ["-qr", join(dir, "release.zip"), "stillfail"], { cwd: join(dir, "release") });
    const sha = createHash("sha256").update(readFileSync(join(dir, "release.zip"))).digest("hex");
    const data = join(dir, "data");
    mkdirSync(join(data, "mesh"), { recursive: true });
    writeFileSync(join(data, "mesh", "cloud.json"), "{}");
    const script = join(dir, "install.ps1");
    writeFileSync(script, bundledWindowsInstallScript("en"));
    const run = (sha256: string) =>
      new Promise<{ code: number; out: string }>((resolve) =>
        execFile(powershell!, ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script], {
          env: { ...process.env, STILLFAIL_ORIGIN: `http://127.0.0.1:${(server.address() as { port: number }).port}`, STILLFAIL_DATA: data, STILLFAIL_RELEASE_SHA256: sha256, STILLFAIL_INSTALL_LANG: "en", PROCESSOR_ARCHITECTURE: "AMD64", USERPROFILE: dir },
          timeout: 120_000,
        }, (e, out, err) => resolve({ code: e ? ((e as { code?: number }).code ?? 1) : 0, out: out + err })),
      );
    const bad = await run("0".repeat(64));
    assert.equal(bad.code, 1, bad.out);
    assert.match(bad.out, /doesn't match its signature/);
    assert.ok(!existsSync(join(data, "handed")) && !existsSync(join(data, "app")));
    const good = await run(sha);
    assert.equal(good.code, 0, good.out);
    assert.equal(readFileSync(join(data, "handed"), "utf8").trim(), "handed 1 True");
  } finally {
    server.close();
    rmSync(dir, { recursive: true, force: true });
  }
});

test("the Windows installer downloads only through Download, which tries again on the way and not on a refusal", () => {
  const script = windowsInstallScript("https://ember.test", "stable", "en");
  const fn = script.match(/^function Download\(.*?^}$/ms)?.[0];
  assert.ok(fn);
  // Every download is its: none left to Invoke-WebRequest once.
  assert.equal(script.replace(fn, "").match(/Invoke-WebRequest/g), null);
  assert.match(fn, /\$status -notin 502, 503, 504/);
  assert.match(fn, /@\(1, 2, 4\)/);
});

test("a Windows download broken on the way or by a gateway is tried again; a refusal, or one broken every time, fails", { skip: !powershell && "no PowerShell" }, async (t) => {
  const { createServer } = await import("node:http");
  /// The server answering, in turn: a status, or "broken" (the connection closed with no answer); 200 once they run out,
  /// or with `broken` every time. (.NET may itself ask again once on a connection closed so: only how many times
  /// Download asked is counted where the connection breaks.)
  let said: (number | "broken")[] = [];
  let broken = false;
  const asked: string[] = [];
  const server = createServer((req, res) => {
    asked.push(req.url ?? "");
    const now = broken ? "broken" : (said.shift() ?? 200);
    if (now === "broken") return void req.socket.destroy();
    res.writeHead(now, { "content-type": "text/plain" }).end(now === 200 ? "the file" : "no");
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  t.after(() => server.close());
  const dir = mkdtempSync(join(tmpdir(), "download-again-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const script = windowsInstallScript("https://ember.test", "stable", "en");
  const fn = script.match(/^function Download\(.*?^}$/ms)![0];
  const file = join(dir, "download.ps1");
  writeFileSync(file, "\ufeff" + `$ErrorActionPreference = 'Stop'\n$ProgressPreference = 'SilentlyContinue'\n${fn}\nDownload $env:TEST_URL (Join-Path $env:TEST_DIR 'got')\n(Download "$env:TEST_URL.sha256").Content\n`);
  const url = `http://127.0.0.1:${(server.address() as { port: number }).port}/releases/x.zip`;
  const run = async (answers: (number | "broken")[], always = false) => {
    said = answers;
    broken = always;
    asked.length = 0;
    rmSync(join(dir, "got"), { force: true });
    const { execFile } = await import("node:child_process");
    const done = await new Promise<{ code: number; out: string }>((resolve) =>
      execFile(powershell!, ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", file], {
        env: { ...process.env, TEST_URL: url, TEST_DIR: dir, STILLFAIL_DOWNLOAD_PAUSES: "0 0 0" }, timeout: 60_000,
      }, (e, out, err) => resolve({ code: e ? ((e as { code?: number }).code ?? 1) : 0, out: out + err })),
    );
    return { ...done, again: done.out.match(/trying again in 0s/g)?.length ?? 0 };
  };
  const gateways = await run([503, 502]);
  assert.equal(gateways.code, 0, gateways.out);
  assert.deepEqual(asked, ["/releases/x.zip", "/releases/x.zip", "/releases/x.zip", "/releases/x.zip.sha256"]);
  assert.equal(readFileSync(join(dir, "got"), "utf8"), "the file");
  assert.equal(gateways.again, 2, gateways.out);
  assert.match(gateways.out, /the file/, "an answer returned when there is no file");
  const once = await run(["broken"]);
  assert.equal(once.code, 0, once.out);
  assert.equal(readFileSync(join(dir, "got"), "utf8"), "the file");
  const refused = await run([404]);
  assert.notEqual(refused.code, 0, refused.out);
  assert.equal(asked.length, 1);
  assert.equal(refused.again, 0);
  const gone = await run([502, 503, 504, 502]);
  assert.notEqual(gone.code, 0, gone.out);
  assert.equal(asked.length, 4);
  assert.equal(gone.again, 3, gone.out);
  assert.ok(!existsSync(join(dir, "got")), "nothing left of it");
  const cut = await run([], true);
  assert.notEqual(cut.code, 0, cut.out);
  assert.equal(cut.again, 3, cut.out);
  assert.ok(asked.length >= 4, asked.join());
  assert.ok(!existsSync(join(dir, "got")), "nothing left of it");
});

test("a Windows release with no NODE_VERSION (the MoonBit station) gets no Node: no download, no node.exe, the old ones' cache taken away", () => {
  const script = windowsInstallScript("https://ember.test", "stable", "en");
  const from = script.indexOf("$nodeDir = $null\nif (Test-Path -LiteralPath (Join-Path $new 'NODE_VERSION')) {\n");
  assert.ok(from > 0);
  const to = script.indexOf("\n}\n", from);
  const block = script.slice(from, to + 3);
  // Every Node the installer asks for, and every node.exe it puts in the release, only inside that block.
  for (const what of ["releases/node/", "node\\node.exe", "Get-Command node.exe"]) {
    const outside = script.replace(block, "");
    assert.ok(block.includes(what), what);
    assert.ok(!outside.includes(what), `${what} outside the block for a release that names its Node`);
  }
  // Its cache beside the data: the others' where it runs on one, all of it where it runs on none.
  assert.match(script, /if \(\$nodeDir\) \{\n  Get-ChildItem \(Join-Path \$data 'node'\) -Directory[^\n]*\n\} else \{\n  Remove-Item -LiteralPath \(Join-Path \$data 'node'\) -Recurse -Force -ErrorAction SilentlyContinue\n\}/);
  // What runs of a release is ended by its programs' names, the MoonBit station's among them.
  assert.match(script, /\$_\.Name -in 'node\.exe', 'stillfail-station\.exe', 'stillfail-station-w\.exe', 'stillfail-reader\.exe'/);
});

test("the Windows installer's Node step, run on a release with no NODE_VERSION, downloads nothing and puts no Node in it", { skip: !powershell && "no PowerShell" }, () => {
  const dir = mkdtempSync(join(tmpdir(), "install-no-node-"));
  try {
    const script = windowsInstallScript("https://ember.test", "stable", "en");
    const from = script.indexOf("$nodeDir = $null\n");
    const block = script.slice(from, script.indexOf("\n}\n", from) + 3);
    const file = join(dir, "node-step.ps1");
    const asked = join(dir, "asked");
    writeFileSync(file, "﻿" + [
      "$ErrorActionPreference = 'Stop'",
      "function Fail([string]$t) { throw $t }",
      "function Say([string]$t) { }",
      "function Download { Add-Content -LiteralPath $env:TEST_ASKED -Value ($args -join ' ') }",
      "$new = Join-Path $env:TEST_DIR 'new'; $data = Join-Path $env:TEST_DIR 'data'; $tmp = Join-Path $env:TEST_DIR 'tmp'; $origin = 'https://ember.test'",
      "New-Item -ItemType Directory -Force $new, $data, $tmp | Out-Null",
      block,
      "if ($nodeDir) { 'node ' + $nodeDir } else { 'no node' }",
    ].join("\n"));
    const ran = spawnSync(powershell!, ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", file], {
      env: { ...process.env, TEST_DIR: dir, TEST_ASKED: asked }, encoding: "utf8",
    });
    assert.equal(ran.status, 0, ran.stdout + ran.stderr);
    assert.equal(ran.stdout.trim(), "no node");
    assert.ok(!existsSync(asked), "nothing downloaded");
    assert.ok(!existsSync(join(dir, "new", "node")), "no node.exe in the release");
    assert.ok(!existsSync(join(dir, "data", "node")), "no Node kept for it");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
