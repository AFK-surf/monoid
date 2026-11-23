import assert from "node:assert/strict";
import { execFileSync, spawn, spawnSync } from "node:child_process";
import { chmodSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, readlinkSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { createServer } from "node:net";
import { dirname, join } from "node:path";
import test from "node:test";
import { createHash } from "node:crypto";
import { bundledInstallScript, installScript, releaseType, sharedRelease } from "../src/install.ts";

test("the installer braces every variable that words follow, so no shell takes a character for part of its name", () => {
  const script = installScript("https://ember.test");
  // A $name right before a non-ASCII character: under set -u some shells read the character's first byte as the name's.
  assert.deepEqual(script.match(/\$[A-Za-z_][A-Za-z0-9_]*(?=[^\x00-\x7f])/g) ?? [], []);
  assert.match(script, /程序：\$\{app\}（/);
});

test("without a token the installer only updates a station already in a workspace", () => {
  const script = installScript("https://ember.test");
  assert.match(script, /if \[ -z "\$token" \] && \[ ! -f "\$cur\/mesh\/cloud.json" \]; then/);
  assert.match(script, /if \[ -n "\$token" \]; then\n  echo "加入 workspace…"/);
});

test("an update hands over to the new release only when the running station says it can and its service is unchanged", () => {
  const script = installScript("https://ember.test");
  assert.match(script, /if \[ -n "\$pid" \] && \[ -n "\$\(said handoff\)" \] && \[ -n "\$\(said renew\)" \] && same_service; then/);
  // The caller's PATH is not a change: an update from another shell (an agent's, the station's own) still hands over.
  assert.match(script, /without_path\(\) \{ sed -e 's#<key>PATH<\/key><string>\[\^<\]\*<\/string>##' -e '\/\^Environment=PATH=\/d'/);
  assert.match(script, /kill -USR2 "\$pid"/);
  // Otherwise drained first (when it can be), then restarted as before.
  assert.match(script, /if \[ -z "\$handed" \] && \[ -n "\$pid" \] && \[ -n "\$\(said drain\)" \]/);
  assert.match(script, /kill -USR1 "\$pid"/);
  assert.match(script, /KillMode=process/);
});

test("an update started inside the station restarts it in the background, and one to the running release does nothing", () => {
  const script = installScript("https://ember.test");
  // The drain waits for the caller's own turn: waiting on it there would wait on itself.
  assert.match(script, /if \[ -z "\$handed" \] && \[ -n "\$pid" \] && inside_station; then/);
  assert.match(script, /set -m\n(  #.*\n)*  \( trap '' HUP; restart_and_finish; rm -rf "\$tmp" "\$lock_dir" \) > "\$cur\/run\/update.log" 2>&1 < \/dev\/null &\n  echo \$! > "\$lock_dir\/pid"\n  exit 0/);
  assert.match(script, /cmp -s "\$tmp\/stillfail\/VERSION" "\$app\/VERSION" && same_service; then/);
});

test("the releases bucket serves the station's releases and the apps' builds, and nothing else", () => {
  assert.equal(releaseType("stillfail-station-linux-x64.tar.gz"), "application/gzip");
  // The last release from before the rename, for installers from before it.
  assert.equal(releaseType("ember-station-linux-x64.tar.gz"), null);
  assert.equal(releaseType("other-station-linux-x64.tar.gz"), null);
  // The Node a release runs on, kept apart from it once per version, with its checksum.
  assert.equal(releaseType("node/node-v24.21.0-linux-x64.tar.gz"), "application/gzip");
  assert.equal(releaseType("node/node-v24.21.0-darwin-arm64.tar.gz.sha256"), "text/plain; charset=utf-8");
  assert.equal(releaseType("node/node-latest-linux-x64.tar.gz"), null);
  assert.equal(releaseType("node/other.tar.gz"), null);
  assert.equal(releaseType("desktop/stillfail-mac.yml"), "text/yaml; charset=utf-8");
  assert.equal(releaseType("desktop/stillfail-0.1.1092-arm64-mac.zip"), "application/zip");
  assert.equal(releaseType("desktop/stillfail-0.1.1092-arm64-mac.zip.blockmap"), "application/octet-stream");
  // The Mac app's own updater's feeds (mbui's, in the Electron app's place), naming the zips above.
  assert.equal(releaseType("mac/latest.json"), "application/json");
  assert.equal(releaseType("mac/beta/latest.json"), "application/json");
  assert.equal(releaseType("mac/other/latest.json"), null);
  // and the Windows one's (mbui's, the beta's first), naming the installers below.
  assert.equal(releaseType("win/latest.json"), "application/json");
  assert.equal(releaseType("win/beta/latest.json"), "application/json");
  assert.equal(releaseType("win/other/latest.json"), null);
  // The Windows app's: its feed (named by the channel alone), its installer and that one's blockmap.
  assert.equal(releaseType("desktop/stillfail.yml"), "text/yaml; charset=utf-8");
  assert.equal(releaseType("desktop/stillfail-beta.yml"), "text/yaml; charset=utf-8");
  assert.equal(releaseType("desktop/web/stillfail-beta-web.json"), "application/json");
  assert.equal(releaseType("desktop/web/stillfail-beta-web-0.1.3000.tar.gz"), "application/gzip");
  assert.equal(releaseType("desktop/web/../station.json"), null);
  assert.equal(releaseType("desktop/stillfail-0.1.2400-x64-win.exe"), "application/vnd.microsoft.portable-executable");
  assert.equal(releaseType("desktop/stillfail-beta-0.1.2400-x64-win.exe.blockmap"), "application/octet-stream");
  assert.equal(releaseType("desktop/stillfail-0.1.2400-arm64-win.exe"), null);
  assert.equal(releaseType("desktop/other.yml"), null);
  // The old app's feed is not served: it is replaced by hand.
  assert.equal(releaseType("desktop/latest-mac.yml"), null);
  assert.equal(releaseType("desktop/ember-0.1.1092-arm64-mac.zip"), null);
  assert.equal(releaseType("desktop/other-mac.yml"), null);
  // The modules' packages are gone (with the station's modules): nothing under modules/.
  for (const file of ["modules/media/media.json", "modules/media/media-0.1.3600.tar.gz"]) assert.equal(releaseType(file), null, file);
  // The prebuilt native parts (scripts/native.ts prebuild), by part, target and key.
  assert.equal(releaseType("natives/shell-win32-x64-e873ee4f2e77b28f78c16a38.tar.gz"), "application/gzip");
  assert.equal(releaseType("natives/engine-win32-x64-95311552b24140105c1a54aa.tar.gz"), "application/gzip");
  for (const file of ["natives/shell-win32-x64-e873.tar.gz", "natives/shell-other-e873ee4f2e77b28f78c16a38.tar.gz", "natives/../station.json", "natives/x/shell-win32-x64-e873ee4f2e77b28f78c16a38.tar.gz"]) {
    assert.equal(releaseType(file), null, file);
  }
  // The relays' iroh-relay (.github/workflows/relay.yml), by the iroh commit it is built from.
  assert.equal(releaseType("relay/iroh-relay-43a6892ffe0689de0cf2545e3a8f3d567146b408-linux-x64"), "application/octet-stream");
  for (const file of ["relay/iroh-relay-43a6892f-linux-x64", "relay/iroh-relay-43a6892ffe0689de0cf2545e3a8f3d567146b408-darwin-arm64", "relay/../station.json"]) {
    assert.equal(releaseType(file), null, file);
  }
  assert.equal(releaseType("relay/dht-node-43a6892ffe0689de0cf2545e3a8f3d567146b408-linux-x64"), "application/octet-stream");
  assert.equal(releaseType("relay/dht-node-43a6892f-linux-x64"), null);
  assert.equal(releaseType("android/latest.json"), "application/json");
  assert.equal(releaseType("station.json"), "application/json");
  assert.equal(releaseType("android/stillfail-1124.apk"), "application/vnd.android.package-archive");
  // Builds from before the rename keep being served: the latest.json of then names them.
  assert.equal(releaseType("android/ember-890.apk"), null);
  // monoid's apps, in its own bucket
  for (const name of ["android/monoid-beta-7300.apk", "android/monoid-7300.apk", "desktop/monoid-beta-0.1.7300-arm64-mac.zip", "desktop/monoid-0.1.7300-x64-win.exe", "desktop/monoid-beta-0.1.7300-x64-win.exe.sig"]) {
    assert.notEqual(releaseType(name), null, name);
  }
  assert.equal(releaseType("android/other-890.apk"), null);
  assert.equal(releaseType("android/../secret"), null);
  assert.equal(releaseType("desktop/other.zip"), null);
  // Signed station included-changes manifests (channel-free, content-addressed).
  assert.equal(releaseType("station/included/11125-0123456789abcdef.json"), "application/json");
  assert.equal(sharedRelease("station/included/11125-0123456789abcdef.json"), true);
  assert.equal(releaseType("station/included/11125-bad.json"), null);
  assert.equal(sharedRelease("station/included/11125-bad.json"), false);
});

test("install.sh does not short-circuit upToDate when OVERRIDE exists, and cleans app.before-replace on official update", () => {
  const script = installScript("https://ember.test");
  assert.match(script, /\[ ! -f "\$app\/OVERRIDE" \] && \[ -f "\$app\/VERSION" \] && cmp -s "\$tmp\/stillfail\/VERSION" "\$app\/VERSION"/);
  assert.match(script, /rm -rf "\$app\.old" "\$data\/app\.before-replace"/);
});

/**
 * Runs the installer on a machine made up in a temporary directory: its HOME, a release of a stand-in command (it says
 * what it was asked), and launchctl, curl and uname that say what they were asked (a Mac, whatever runs the test).
 * `os` "linux" or "wsl" makes it a Linux (x64) instead, with a systemd for the user (`systemd`) or none; "wsl" is
 * Windows' Linux (its kernel says microsoft) with Windows' cmd.exe and wslpath, its drive C: in <root>/c.
 */
function machine(os: "mac" | "linux" | "wsl" = "mac", systemd = true, base = tmpdir()) {
  const root = mkdtempSync(join(base, "install-test-"));
  const home = join(root, "home");
  const stub = join(root, "stub");
  const release = join(root, "release", "stillfail");
  mkdirSync(home, { recursive: true });
  mkdirSync(stub);
  mkdirSync(join(release, "bin"), { recursive: true });
  writeFileSync(join(release, "bin", "stillfail"), '#!/bin/sh\necho "${STILLFAIL_DATA:+data=$STILLFAIL_DATA }stillfail $*" >> "$HOME/said"\n', { mode: 0o755 });
  symlinkSync("stillfail", join(release, "bin", "ember"));
  writeFileSync(join(release, "VERSION"), "new\n");
  execFileSync("tar", ["-czf", join(root, "release.tar.gz"), "-C", join(root, "release"), "stillfail"]);
  const tool = (name: string, body: string) => writeFileSync(join(stub, name), `#!/bin/sh\necho "${name} $*" >> "$HOME/said"\n${body}`, { mode: 0o755 });
  tool("launchctl", '[ "$1" = print ] && exit 1\nexit 0\n');
  tool("curl", `while [ $# -gt 0 ]; do [ "$1" = -o ] && cp "${join(root, "release.tar.gz")}" "$2"; shift; done\n`);
  if (os === "mac") tool("uname", '[ "$1" = -m ] && echo arm64 || echo Darwin\n');
  else tool("uname", '[ "$1" = -m ] && echo x86_64 || echo Linux\n');
  const osrelease = join(root, "osrelease");
  writeFileSync(osrelease, os === "wsl" ? "6.6.87.2-microsoft-standard-WSL2\n" : "6.8.0-45-generic\n");
  tool("systemctl", systemd ? "exit 0\n" : "exit 1\n");
  tool("loginctl", "exit 0\n");
  if (os === "wsl") {
    mkdirSync(join(root, "c/Users/kim/AppData/Roaming/Microsoft/Windows/Start Menu/Programs/Startup"), { recursive: true });
    tool("cmd.exe", 'case "$*" in *APPDATA*) printf \'%s\\r\\n\' \'C:\\Users\\kim\\AppData\\Roaming\' ;; esac\n');
    tool("wslpath", `case $1 in
  -u) printf '%s\\n' "$2" | sed -e 's#^C:#${root}/c#' -e 's#\\\\#/#g' ;;
  -w) printf '%s\\n' "$2" | sed -e 's#^${root}/c#C:#' -e 's#/#\\\\#g' ;;
esac
`);
    tool("pgrep", "exit 1\n");
  }
  const run = (args: string[] = [], env: Record<string, string> = {}, installer = installScript("https://app.still.fail")) => {
    const script = installer.replaceAll("/proc/sys/kernel/osrelease", osrelease);
    const done = spawnSync("sh", ["-c", script, "sh", ...args], {
      // Only these: not the caller's (an agent's STILLFAIL_DATA would aim it at the real station).
      env: { HOME: home, PATH: `${stub}:/usr/bin:/bin:/usr/sbin:/sbin`, ...env } as unknown as NodeJS.ProcessEnv,
      encoding: "utf8",
    });
    return { status: done.status, out: done.stdout + done.stderr, said: existsSync(join(home, "said")) ? readFileSync(join(home, "said"), "utf8") : "" };
  };
  return { root, home, run, done: () => rmSync(root, { recursive: true, force: true }) };
}

test("the Mac service preserves XML characters in its data directory and PATH", () => {
  const m = machine();
  try {
    const data = join(m.root, "station & <work>");
    const extra = join(m.root, "tools & <local>");
    const done = m.run(["tok"], { STILLFAIL_DATA: data, PATH: `${join(m.root, "stub")}:${extra}:/usr/bin:/bin:/usr/sbin:/sbin` });
    assert.equal(done.status, 0, done.out);
    // Parse the service launchd would read, rather than only checking the XML's spelling.
    const plist = JSON.parse(execFileSync("python3", ["-c", "import json, plistlib, sys; print(json.dumps(plistlib.load(open(sys.argv[1], 'rb'))))", join(m.home, "Library/LaunchAgents/fail.still.station.plist")], { encoding: "utf8" }));
    assert.deepEqual(plist.ProgramArguments, [join(data, "app/bin/stillfail"), "start"]);
    assert.equal(plist.EnvironmentVariables.STILLFAIL_DATA, data);
    assert.ok(plist.EnvironmentVariables.PATH.split(":").includes(extra));
    assert.equal(plist.StandardOutPath, join(data, "stillfail.log"));
    assert.equal(plist.StandardErrorPath, join(data, "stillfail.log"));
  } finally {
    m.done();
  }
});

test("in WSL the station runs without Windows' PATH, and Windows keeps WSL up from its sign-in on", () => {
  const m = machine("wsl");
  try {
    const done = m.run(["tok"], { WSL_DISTRO_NAME: "Ubuntu", PATH: `${join(m.root, "stub")}:/usr/bin:/bin:/mnt/c/Program Files/nodejs:/mnt/c/Windows` });
    assert.equal(done.status, 0, done.out);
    const unit = readFileSync(join(m.home, ".config/systemd/user/stillfail-station.service"), "utf8");
    const path = /^Environment=PATH=(.*)$/m.exec(unit)?.[1] ?? "";
    assert.match(path, /\/usr\/bin/);
    assert.doesNotMatch(path, /\/mnt\//, "none of Windows' directories");
    const keeper = join(m.root, "c/Users/kim/AppData/Roaming/Microsoft/Windows/Start Menu/Programs/Startup/stillfail-station-Ubuntu.vbs");
    assert.equal(readFileSync(keeper, "utf8"), 'CreateObject("WScript.Shell").Run "wsl.exe -d ""Ubuntu"" --exec sleep 3153600000", 0, False\r\n');
    // Started now too, as at the next sign-in.
    assert.match(done.said, /cmd\.exe \/c wscript\.exe C:\\Users\\kim\\AppData\\Roaming\\Microsoft\\Windows\\Start Menu\\Programs\\Startup\\stillfail-station-Ubuntu\.vbs/);
    assert.match(done.out, /stillfail-station-Ubuntu\.vbs/);
    assert.match(done.said, /systemctl --user enable stillfail-station\.service/);
  } finally {
    m.done();
  }
  const bare = machine("wsl", false);
  try {
    // No systemd: run in the background, and told how to turn it on (no keeper: nothing would start it with WSL).
    const done = bare.run(["tok"], { WSL_DISTRO_NAME: "Ubuntu" });
    assert.equal(done.status, 0, done.out);
    assert.match(done.out, /\/etc\/wsl\.conf/);
    assert.doesNotMatch(done.said, /wscript/);
  } finally {
    bare.done();
  }
  const linux = machine("linux");
  try {
    // Another Linux keeps its PATH as it is and hears nothing of WSL.
    const done = linux.run(["tok"], { PATH: `${join(linux.root, "stub")}:/usr/bin:/bin:/mnt/tools/bin` });
    assert.equal(done.status, 0, done.out);
    assert.match(readFileSync(join(linux.home, ".config/systemd/user/stillfail-station.service"), "utf8"), /^Environment=PATH=.*:\/mnt\/tools\/bin/m);
    // (its own words: the test's directory, named at random, may hold the letters too, as install-test-6JZWSL did)
    assert.doesNotMatch(done.out.replaceAll(linux.root, ""), /WSL/);
  } finally {
    linux.done();
  }
});

test("a directory it writes in that a sudo made root's stops the install before the download, saying how to give it back", { skip: process.getuid?.() === 0 && "root writes anywhere" }, () => {
  const m = machine("linux");
  try {
    // ~/.config made by an earlier sudo command (2026-11-17: mkdir's "Permission denied" once the machine had joined).
    mkdirSync(join(m.home, ".config"));
    chmodSync(join(m.home, ".config"), 0o555);
    const done = m.run(["tok"]);
    assert.equal(done.status, 1, done.out);
    assert.match(done.out, new RegExp(`无法写入 ${join(m.home, ".config")}：.*sudo chown -R \\S+ ${join(m.home, ".config")}`));
    // Nothing done yet: not downloaded, not joined.
    assert.doesNotMatch(done.said, /curl|enroll/);
    assert.ok(!existsSync(join(m.home, ".stillfail", "app")));
    chmodSync(join(m.home, ".config"), 0o755);
    assert.equal(m.run(["tok"]).status, 0);
  } finally {
    chmodSync(join(m.home, ".config"), 0o755);
    m.done();
  }
});

test("with both places there the new one is used and the old one left; a fresh machine gets only the new one", () => {
  const both = machine();
  try {
    mkdirSync(join(both.home, ".ember"), { recursive: true });
    writeFileSync(join(both.home, ".ember", "config.json"), "old");
    mkdirSync(join(both.home, ".stillfail", "mesh"), { recursive: true });
    writeFileSync(join(both.home, ".stillfail", "mesh", "cloud.json"), '{"origin": "https://app.still.fail"}');
    const done = both.run();
    assert.equal(done.status, 0, done.out);
    assert.ok(lstatSync(join(both.home, ".ember")).isDirectory());
    assert.equal(readFileSync(join(both.home, ".ember", "config.json"), "utf8"), "old");
    assert.ok(existsSync(join(both.home, ".stillfail", "app", "VERSION")));
  } finally {
    both.done();
  }
  const fresh = machine();
  try {
    const done = fresh.run(["tok"]);
    assert.equal(done.status, 0, done.out);
    assert.ok(existsSync(join(fresh.home, ".stillfail", "app", "VERSION")));
    assert.ok(!existsSync(join(fresh.home, ".ember")));
    assert.match(done.said, /stillfail station enroll https:\/\/app\.still\.fail tok --stay/);
  } finally {
    fresh.done();
  }
});

test("another product's station is installed beside still.fail's: its own data, command and service", () => {
  const both = machine();
  try {
    mkdirSync(join(both.home, ".stillfail", "mesh"), { recursive: true });
    writeFileSync(join(both.home, ".stillfail", "mesh", "cloud.json"), '{"origin": "https://app.still.fail"}');
    const done = both.run(["tok"], {}, installScript("https://app.monoid.build"));
    assert.equal(done.status, 0, done.out);
    assert.ok(existsSync(join(both.home, ".monoid", "app", "VERSION")));
    assert.ok(!existsSync(join(both.home, ".stillfail", "app")), "still.fail's left as it was");
    assert.equal(readlinkSync(join(both.home, ".local", "bin", "monoid")), join(both.home, ".monoid", "app", "bin", "stillfail"));
    assert.ok(!existsSync(join(both.home, ".local", "bin", "stillfail")) && !existsSync(join(both.home, ".local", "bin", "ember")));
    const plist = readFileSync(join(both.home, "Library", "LaunchAgents", "build.monoid.station.plist"), "utf8");
    assert.match(plist, new RegExp(`<key>STILLFAIL_DATA</key><string>${join(both.home, ".monoid")}</string>`));
    assert.ok(!existsSync(join(both.home, "Library", "LaunchAgents", "fail.still.station.plist")));
    // enrolled in its own data, not still.fail's: called as `stillfail`, the command would take ~/.stillfail
    assert.ok(done.said.includes(`data=${join(both.home, ".monoid")} stillfail station enroll https://app.monoid.build tok --stay`), done.said);
    // still.fail's service is never stopped for it
    assert.doesNotMatch(done.said, /launchctl bootout \S*fail\.still\.station|org\.3720\.ember\.station/);
  } finally {
    both.done();
  }
});

test("the release says which channel it came from, for the station to go back from the beta", () => {
  const m = machine();
  try {
    const beta = m.run(["tok"], { STILLFAIL_CHANNEL: "beta" });
    assert.equal(beta.status, 0, beta.out);
    assert.match(beta.said, /curl .*\/releases\/beta\/stillfail-station-darwin-arm64\.tar\.gz/);
    assert.equal(readFileSync(join(m.home, ".stillfail", "app", "CHANNEL"), "utf8"), "beta\n");
    // In a workspace now: updated without a token, on a channel it does not know (the stable one).
    mkdirSync(join(m.home, ".stillfail", "mesh"), { recursive: true });
    writeFileSync(join(m.home, ".stillfail", "mesh", "cloud.json"), '{"origin": "https://app.still.fail"}');
    const stable = m.run([], { STILLFAIL_CHANNEL: "anything" });
    assert.equal(stable.status, 0, stable.out);
    assert.equal(readFileSync(join(m.home, ".stillfail", "app", "CHANNEL"), "utf8"), "stable\n");
  } finally {
    m.done();
  }
});

test("a handover the new release cannot take leaves the station running on the old release, not restarted", () => {
  const m = machine();
  const data = join(m.home, ".stillfail");
  let pid = 0;
  try {
    mkdirSync(join(data, "mesh"), { recursive: true });
    writeFileSync(join(data, "mesh", "cloud.json"), '{"origin": "https://app.still.fail"}');
    assert.equal(m.run().status, 0, "installed, with its service");
    writeFileSync(join(data, "app", "VERSION"), "old\n");
    // The running station, as ps tells it: asked to hand over (SIGUSR2), it says its new Node did not come up.
    const fake = join(m.root, "stillfail-station");
    writeFileSync(
      fake,
      `#!/bin/sh\ntrap 'echo "the new release did not start" > "${data}/run/handoff-failed"' USR2\ntouch "${m.root}/listening"\nwhile :; do sleep 0.2; done\n`,
      { mode: 0o755 },
    );
    // Not this process's child (the installer runs while this waits, so none is reaped here): one that has ended goes.
    pid = Number(execFileSync("sh", ["-c", `"${fake}" </dev/null >/dev/null 2>&1 & echo $!`], { encoding: "utf8" }));
    while (!existsSync(join(m.root, "listening"))) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 50);
    mkdirSync(join(data, "run"), { recursive: true });
    const said = `{"pid": ${pid}, "startedAt": 1700000000000, "handoff": 1, "drain": 1, "renew": 1}`;
    writeFileSync(join(data, "run", "station.json"), said);
    writeFileSync(join(m.home, "said"), "");

    const update = m.run();
    assert.equal(update.status, 1, update.out);
    assert.match(update.out, /the new release did not start/);
    assert.match(update.out, /无法交接.*station 继续使用原版本运行|Couldn't hand over.*keeps running the previous version/);
    assert.equal(readFileSync(join(data, "app", "VERSION"), "utf8"), "old\n", "the old release back in its place");
    assert.ok(!existsSync(join(data, "app.old")) && !existsSync(join(data, "app.failed")));
    assert.ok(process.kill(pid, 0), "the station still runs");
    assert.doesNotMatch(update.said, /launchctl (bootout|bootstrap)/, "and is not restarted");
    assert.equal(readFileSync(join(data, "run", "station.json"), "utf8"), said);
  } finally {
    if (pid) process.kill(pid, "SIGKILL");
    m.done();
  }
});

test("a station whose launcher would not become the new release's own is restarted once, not handed over", () => {
  const m = machine();
  const data = join(m.home, ".stillfail");
  let pid = 0;
  try {
    mkdirSync(join(data, "mesh"), { recursive: true });
    writeFileSync(join(data, "mesh", "cloud.json"), '{"origin": "https://app.still.fail"}');
    assert.equal(m.run().status, 0, "installed, with its service");
    writeFileSync(join(data, "app", "VERSION"), "old\n");
    // A launcher from before (its station.json says no renew): it hands over to new Nodes, itself never changed.
    const fake = join(m.root, "stillfail-station");
    writeFileSync(
      fake,
      `#!/bin/sh\ntrap 'echo handover >> "${m.root}/told"' USR2\ntrap 'echo drain >> "${m.root}/told"; echo idle > "${data}/run/drained"' USR1\ntouch "${m.root}/listening"\nwhile :; do sleep 0.2; done\n`,
      { mode: 0o755 },
    );
    pid = Number(execFileSync("sh", ["-c", `"${fake}" </dev/null >/dev/null 2>&1 & echo $!`], { encoding: "utf8" }));
    while (!existsSync(join(m.root, "listening"))) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 50);
    mkdirSync(join(data, "run"), { recursive: true });
    writeFileSync(join(data, "run", "station.json"), `{"pid": ${pid}, "startedAt": 1700000000000, "handoff": 1, "drain": 1, "channel": 1}`);
    writeFileSync(join(m.home, "said"), "");

    const update = m.run();
    assert.equal(update.status, 0, update.out);
    assert.equal(readFileSync(join(m.root, "told"), "utf8"), "drain\n", "drained, never asked to hand over");
    assert.match(update.said, /launchctl bootout/);
    assert.match(update.said, /launchctl bootstrap/);
    assert.equal(readFileSync(join(data, "app", "VERSION"), "utf8"), "new\n");
  } finally {
    if (pid) process.kill(pid, "SIGKILL");
    m.done();
  }
});

// still.fail's container (station/docker): its entrypoint runs the station, starting it again whenever it ends, once
// no install holds run/install.lock.
test("in still.fail's container the installer starts no station, and a restart only ends the running one, the entrypoint starting the new release", () => {
  const m = machine("linux", false);
  const data = join(m.home, ".stillfail");
  const container = { STILLFAIL_CONTAINER: "1" };
  let pid = 0;
  try {
    const fresh = m.run(["tok"], container);
    assert.equal(fresh.status, 0, fresh.out);
    assert.match(fresh.said, /stillfail station enroll https:\/\/app\.still\.fail tok --stay/);
    assert.doesNotMatch(fresh.said, /stillfail start/, "started by the entrypoint, not here");
    assert.ok(!existsSync(join(data, "stillfail.pid")));
    assert.match(fresh.out, /still\.fail 的容器|still\.fail's container/);
    assert.doesNotMatch(fresh.out, /systemd/);

    // A launcher from before (no renew): restarted, by ending it; the entrypoint starts the new release.
    writeFileSync(join(data, "app", "VERSION"), "old\n");
    mkdirSync(join(data, "mesh"), { recursive: true });
    writeFileSync(join(data, "mesh", "cloud.json"), '{"origin": "https://app.still.fail"}');
    const fake = join(m.root, "stillfail-station");
    writeFileSync(
      fake,
      `#!/bin/sh\ntrap 'echo drain >> "${m.root}/told"; echo idle > "${data}/run/drained"' USR1\ntrap 'echo end >> "${m.root}/told"; exit 0' TERM\ntouch "${m.root}/listening"\nwhile :; do sleep 0.2; done\n`,
      { mode: 0o755 },
    );
    pid = Number(execFileSync("sh", ["-c", `"${fake}" </dev/null >/dev/null 2>&1 & echo $!`], { encoding: "utf8" }));
    while (!existsSync(join(m.root, "listening"))) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 50);
    mkdirSync(join(data, "run"), { recursive: true });
    writeFileSync(join(data, "run", "station.json"), `{"pid": ${pid}, "startedAt": 1700000000000, "handoff": 1, "drain": 1}`);
    writeFileSync(join(m.home, "said"), "");

    const update = m.run([], container);
    assert.equal(update.status, 0, update.out);
    assert.equal(readFileSync(join(m.root, "told"), "utf8"), "drain\nend\n", "drained, then ended");
    assert.doesNotMatch(update.said, /stillfail start/);
    assert.equal(readFileSync(join(data, "app", "VERSION"), "utf8"), "new\n");
    assert.ok(!existsSync(join(data, "run", "install.lock")), "the lock let go of, for the entrypoint to start it");
  } finally {
    if (pid) {
      try {
        process.kill(pid, "SIGKILL");
      } catch {}
    }
    m.done();
  }
});

// Two at once (the station updating itself as CI's `stillfail update` ran, 2026-11-04) each put aside the app the other
// had just put in, and the release that could not start was put back as the old one.
test("an install waits for the one under way, and takes over one whose installer is gone", () => {
  const m = machine();
  const data = join(m.home, ".stillfail");
  try {
    mkdirSync(join(data, "mesh"), { recursive: true });
    writeFileSync(join(data, "mesh", "cloud.json"), '{"origin": "https://app.still.fail"}');
    assert.equal(m.run().status, 0, "installed, with its service");
    const lock = join(data, "run", "install.lock");

    // Another install under way: this one does nothing until it has ended.
    writeFileSync(join(data, "app", "VERSION"), "old\n");
    writeFileSync(join(m.home, "said"), "");
    mkdirSync(lock);
    const other = execFileSync("sh", ["-c", `(sleep 1; echo "the other install ended" >> "${m.home}/said"; rm -rf "${lock}") </dev/null >/dev/null 2>&1 & echo $!`], { encoding: "utf8" });
    writeFileSync(join(lock, "pid"), other);
    let update = m.run();
    assert.equal(update.status, 0, update.out);
    const ended = update.said.indexOf("the other install ended");
    assert.ok(ended >= 0 && ended < update.said.indexOf("launchctl bootout"), update.said);
    assert.equal(readFileSync(join(data, "app", "VERSION"), "utf8"), "new\n");
    assert.ok(!existsSync(lock), "and let go of when done");

    // One whose installer is gone (killed mid-way): taken over.
    writeFileSync(join(data, "app", "VERSION"), "old\n");
    mkdirSync(lock);
    writeFileSync(join(lock, "pid"), execFileSync("sh", ["-c", "sh -c 'exit 0' & echo $!; wait"], { encoding: "utf8" }));
    update = m.run();
    assert.equal(update.status, 0, update.out);
    assert.equal(readFileSync(join(data, "app", "VERSION"), "utf8"), "new\n");
    assert.ok(!existsSync(lock));
  } finally {
    m.done();
  }
});

const sha256Of = (file: string) => createHash("sha256").update(readFileSync(file)).digest("hex");

test("a station updating itself installs only the release its signed words name, by that release's own installer", () => {
  const m = machine();
  const data = join(m.home, ".stillfail");
  try {
    mkdirSync(join(data, "mesh"), { recursive: true });
    writeFileSync(join(data, "mesh", "cloud.json"), '{"origin": "https://app.still.fail"}');
    // The release carries its installer (scripts/installers.ts), here one that says it ran and what it was handed.
    const own = bundledInstallScript("zh").replace("set -eu\n", 'set -eu\necho "its own installer: $STILLFAIL_INSTALLER_HANDED $(basename "$STILLFAIL_ARCHIVE")" >> "$HOME/said"\n');
    const release = join(m.root, "release", "stillfail");
    writeFileSync(join(release, "bin", "install.zh.sh"), own);
    execFileSync("tar", ["-czf", join(m.root, "release.tar.gz"), "-C", join(m.root, "release"), "stillfail"]);
    const sha = sha256Of(join(m.root, "release.tar.gz"));
    const bundled = bundledInstallScript("zh");
    const told = { STILLFAIL_ORIGIN: "https://releases.test", STILLFAIL_INSTALL_LANG: "zh" };

    // Not where the station names (no STILLFAIL_ORIGIN): nothing.
    assert.notEqual(m.run([], {}, bundled).status, 0);
    // A download that is not the signed release: not installed.
    const bad = m.run([], { ...told, STILLFAIL_RELEASE_SHA256: "0".repeat(64) }, bundled);
    assert.equal(bad.status, 1, bad.out);
    assert.match(bad.out, /与签名不符/);
    assert.ok(!existsSync(join(data, "app")), "nothing installed");
    assert.match(bad.said, /curl .*https:\/\/releases\.test\/releases\/stillfail-station-darwin-arm64\.tar\.gz/);

    // The signed one: downloaded once, then installed by the installer it carries, handed the download.
    writeFileSync(join(m.home, "said"), "");
    const good = m.run([], { ...told, STILLFAIL_RELEASE_SHA256: sha }, bundled);
    assert.equal(good.status, 0, good.out);
    assert.equal(readFileSync(join(data, "app", "VERSION"), "utf8"), "new\n");
    assert.match(good.said, /its own installer: 1 stillfail\.tar\.gz/);
    assert.equal(good.said.match(/^curl /gm)?.length, 1, good.said);
    // The download it was handed is gone with its directory.
    assert.deepEqual(readdirSync("/tmp").filter((f) => f.startsWith("stillfail-handed.") && existsSync(join("/tmp", f, "stillfail.tar.gz")) && sha256Of(join("/tmp", f, "stillfail.tar.gz")) === sha), []);
  } finally {
    m.done();
  }
});

test("a download broken on the way (curl's exit 35, a gateway's 503) is tried again; a refusal, or one broken every time, fails the install", () => {
  /// curl answering, in turn, `said`: "35" a TLS connection broken (SSL_ERROR_SYSCALL), an HTTP status as curl -f
  /// fails on it (exit 22, the status written by -w), "ok" the release written to -o; "ok" once they run out.
  const answering = (m: ReturnType<typeof machine>, said: string[]) => {
    writeFileSync(join(m.root, "answers"), said.join("\n") + "\n");
    writeFileSync(join(m.root, "stub", "curl"), `#!/bin/sh
echo "curl $*" >> "$HOME/said"
now=$(head -n 1 "${join(m.root, "answers")}"); sed -i.x 1d "${join(m.root, "answers")}"
case "\${now:-ok}" in
  35) echo "curl: (35) LibreSSL SSL_connect: SSL_ERROR_SYSCALL in connection to app.still.fail:443" >&2; exit 35 ;;
  [0-9][0-9][0-9]) printf %s "$now"; exit 22 ;;
esac
while [ $# -gt 0 ]; do [ "$1" = -o ] && cp "${join(m.root, "release.tar.gz")}" "$2"; shift; done
printf 200
`, { mode: 0o755 });
  };
  const pauses = { STILLFAIL_DOWNLOAD_PAUSES: "0 0 0" };
  for (const [name, said, ok, tries] of [
    ["broken twice", ["35", "35"], true, 3],
    ["a gateway's 503, then broken", ["503", "35"], true, 3],
    ["broken every time", ["35", "35", "35", "35"], false, 4],
    ["not found", ["404"], false, 1],
    ["a server's error", ["500"], false, 1],
  ] as const) {
    const m = machine();
    try {
      answering(m, [...said]);
      const done = m.run(["tok"], pauses);
      assert.equal(done.status === 0, ok, `${name}: ${done.out}`);
      assert.equal(done.said.match(/^curl /gm)?.length, tries, `${name}: ${done.said}`);
      assert.equal(done.out.match(/下载中断，0 秒后重试/g)?.length ?? 0, tries - 1, `${name}: ${done.out}`);
      assert.equal(existsSync(join(m.home, ".stillfail", "app", "VERSION")), ok, name);
    } finally {
      m.done();
    }
  }
});

test("a station hands its installer the release's raw tar a delta made: checked by its hash, unpacked and handed on, nothing downloaded", () => {
  const m = machine();
  const data = join(m.home, ".stillfail");
  try {
    mkdirSync(join(data, "mesh"), { recursive: true });
    writeFileSync(join(data, "mesh", "cloud.json"), '{"origin": "https://app.still.fail"}');
    const own = bundledInstallScript("zh").replace("set -eu\n", 'set -eu\necho "its own installer: $STILLFAIL_INSTALLER_HANDED $STILLFAIL_RELEASE_SHA256" >> "$HOME/said"\n');
    const release = join(m.root, "release", "stillfail");
    writeFileSync(join(release, "bin", "install.zh.sh"), own);
    // The tar itself (station/src/updates/release.ts: what a delta makes), under the name a handed archive has.
    execFileSync("tar", ["-cf", join(m.root, "release.tar"), "-C", join(m.root, "release"), "stillfail"]);
    const sha = sha256Of(join(m.root, "release.tar"));
    const handed = mkdtempSync(join(tmpdir(), "stillfail-handed."));
    writeFileSync(join(handed, "stillfail.tar.gz"), readFileSync(join(m.root, "release.tar")));
    const told = { STILLFAIL_ORIGIN: "https://releases.test", STILLFAIL_INSTALL_LANG: "zh", STILLFAIL_RELEASE_SHA256: sha, STILLFAIL_ARCHIVE: join(handed, "stillfail.tar.gz") };
    const done = m.run([], told, bundledInstallScript("zh"));
    assert.equal(done.status, 0, done.out);
    assert.equal(readFileSync(join(data, "app", "VERSION"), "utf8"), "new\n");
    assert.match(done.said, new RegExp(`its own installer: 1 ${sha}`), "handed on with the same hash");
    assert.doesNotMatch(done.said, /^curl /m, "nothing downloaded");
    assert.ok(!existsSync(handed), "taken, its directory removed");
  } finally {
    m.done();
  }
});

test("a station updating itself runs on the Node its signed words name, the machine's own only when it is that one", () => {
  const m = machine();
  const data = join(m.home, ".stillfail");
  try {
    mkdirSync(join(data, "mesh"), { recursive: true });
    writeFileSync(join(data, "mesh", "cloud.json"), '{"origin": "https://app.still.fail"}');
    const release = join(m.root, "release", "stillfail");
    writeFileSync(join(release, "NODE_VERSION"), "24.21.0\n");
    execFileSync("tar", ["-czf", join(m.root, "release.tar.gz"), "-C", join(m.root, "release"), "stillfail"]);
    // The Node, as node-dist.sh keeps it (bin/node in a tarball): a stand-in that says its version.
    const dist = join(m.root, "node");
    mkdirSync(join(dist, "bin"), { recursive: true });
    writeFileSync(join(dist, "bin", "node"), '#!/bin/sh\necho v24.21.0\n', { mode: 0o755 });
    execFileSync("tar", ["-czf", join(m.root, "node.tar.gz"), "-C", dist, "bin/node"]);
    const stub = join(m.root, "stub");
    writeFileSync(join(stub, "curl"), `#!/bin/sh\necho "curl $*" >> "$HOME/said"\nwhile [ $# -gt 1 ]; do\n  case "$1" in */releases/node/*) node=yes ;; esac\n  [ "$1" = -o ] && { [ -n "\${node:-}" ] && cp "${join(m.root, "node.tar.gz")}" "$2" || cp "${join(m.root, "release.tar.gz")}" "$2"; }\n  shift\ndone\n`, { mode: 0o755 });
    const told = { STILLFAIL_ORIGIN: "https://releases.test", STILLFAIL_RELEASE_SHA256: sha256Of(join(m.root, "release.tar.gz")) };
    const bundled = bundledInstallScript("zh");

    const bad = m.run([], { ...told, STILLFAIL_NODE_SHA256: "0".repeat(64) }, bundled);
    assert.equal(bad.status, 1, bad.out);
    assert.match(bad.out, /Node 24\.21\.0 校验失败/);
    assert.deepEqual(readdirSync(join(data, "node")), [], "nothing of it left");
    // No .sha256 asked for: the signed hash is the binary's own.
    assert.doesNotMatch(bad.said, /\.sha256/);

    // A machine's own node of that version that is not that very binary is not taken.
    const ownBin = join(m.root, "own");
    mkdirSync(ownBin);
    writeFileSync(join(ownBin, "node"), '#!/bin/sh\n# another build\necho v24.21.0\n', { mode: 0o755 });
    const good = m.run([], { ...told, STILLFAIL_NODE_SHA256: sha256Of(join(dist, "bin", "node")), PATH: `${stub}:${ownBin}:/usr/bin:/bin:/usr/sbin:/sbin` }, bundled);
    assert.equal(good.status, 0, good.out);
    assert.equal(readFileSync(join(data, "node", "v24.21.0", "bin", "node"), "utf8"), readFileSync(join(dist, "bin", "node"), "utf8"));
    assert.match(good.said, /curl .*\/releases\/node\/node-v24\.21\.0-darwin-arm64\.tar\.gz/);
  } finally {
    m.done();
  }
});

test("a station updating itself to the MoonBit station (no NODE_VERSION, no main.js) fetches no Node and links none", () => {
  const m = machine();
  const data = join(m.home, ".stillfail");
  try {
    mkdirSync(join(data, "mesh"), { recursive: true });
    writeFileSync(join(data, "mesh", "cloud.json"), '{"origin": "https://app.still.fail"}');
    // what a release from before left: its Node, kept beside the data
    mkdirSync(join(data, "node", "v24.21.0", "bin"), { recursive: true });
    writeFileSync(join(data, "node", "v24.21.0", "bin", "node"), "#!/bin/sh\necho v24.21.0\n", { mode: 0o755 });
    const release = join(m.root, "release", "stillfail");
    mkdirSync(join(release, "station"), { recursive: true });
    writeFileSync(join(release, "station", "stillfail-reader"), "#!/bin/sh\nexit 0\n", { mode: 0o755 });
    execFileSync("tar", ["-czf", join(m.root, "release.tar.gz"), "-C", join(m.root, "release"), "stillfail"]);
    const stub = join(m.root, "stub");
    writeFileSync(join(stub, "curl"), `#!/bin/sh\necho "curl $*" >> "$HOME/said"\nwhile [ $# -gt 1 ]; do\n  [ "$1" = -o ] && cp "${join(m.root, "release.tar.gz")}" "$2"\n  shift\ndone\n`, { mode: 0o755 });
    // signed as scripts/release-sign.ts signs a release with no Node: a node hash of zeros, never read
    const told = { STILLFAIL_ORIGIN: "https://releases.test", STILLFAIL_RELEASE_SHA256: sha256Of(join(m.root, "release.tar.gz")), STILLFAIL_NODE_SHA256: "0".repeat(64) };
    const done = m.run([], told, bundledInstallScript("zh"));
    assert.equal(done.status, 0, done.out);
    assert.match(done.said, /curl .*\/releases\/stillfail-station-darwin-arm64\.tar\.gz/);
    assert.doesNotMatch(done.said, /releases\/node\//, "no Node asked for");
    const app = join(data, "app");
    assert.ok(existsSync(join(app, "station", "stillfail-reader")));
    for (const gone of ["node", "NODE_VERSION", join("station", "main.js")]) assert.throws(() => lstatSync(join(app, gone)), gone);
    // the Node a release from before ran on, taken away once it runs on none
    assert.equal(existsSync(join(data, "node")), false);
  } finally {
    m.done();
  }
});

test("a Node another install put there meanwhile is the one kept, and nothing half-made is left beside it", () => {
  const m = machine();
  const data = join(m.home, ".stillfail");
  try {
    mkdirSync(join(data, "mesh"), { recursive: true });
    writeFileSync(join(data, "mesh", "cloud.json"), '{"origin": "https://app.still.fail"}');
    const release = join(m.root, "release", "stillfail");
    writeFileSync(join(release, "NODE_VERSION"), "24.21.0\n");
    execFileSync("tar", ["-czf", join(m.root, "release.tar.gz"), "-C", join(m.root, "release"), "stillfail"]);
    // A stand-in that, asked its version from where this install unpacked it, has the other install (the station's own
    // update, say) finish first: node/v24.21.0 is there by the time this one would move its own in.
    const dist = join(m.root, "node");
    mkdirSync(join(dist, "bin"), { recursive: true });
    const theirs = '#!/bin/sh\necho v24.21.0 # theirs\n';
    writeFileSync(join(dist, "bin", "node"), `#!/bin/sh\nd="$(cd "$(dirname "$0")/../.." && pwd)/v24.21.0"\n[ -x "$d/bin/node" ] || { mkdir -p "$d/bin"; printf '%s' '${theirs}' > "$d/bin/node"; chmod +x "$d/bin/node"; }\necho v24.21.0\n`, { mode: 0o755 });
    execFileSync("tar", ["-czf", join(m.root, "node.tar.gz"), "-C", dist, "bin/node"]);
    const stub = join(m.root, "stub");
    writeFileSync(join(stub, "curl"), `#!/bin/sh\nwhile [ $# -gt 1 ]; do\n  case "$1" in */releases/node/*) node=yes ;; esac\n  [ "$1" = -o ] && { [ -n "\${node:-}" ] && cp "${join(m.root, "node.tar.gz")}" "$2" || cp "${join(m.root, "release.tar.gz")}" "$2"; }\n  shift\ndone\n`, { mode: 0o755 });
    const run = m.run([], {
      STILLFAIL_ORIGIN: "https://releases.test", STILLFAIL_RELEASE_SHA256: sha256Of(join(m.root, "release.tar.gz")),
      STILLFAIL_NODE_SHA256: sha256Of(join(dist, "bin", "node")), PATH: `${stub}:/usr/bin:/bin:/usr/sbin:/sbin`,
    }, bundledInstallScript("zh"));
    assert.equal(run.status, 0, run.out);
    assert.deepEqual(readdirSync(join(data, "node")), ["v24.21.0"]);
    assert.deepEqual(readdirSync(join(data, "node", "v24.21.0")), ["bin"]);
    assert.equal(readFileSync(join(data, "node", "v24.21.0", "bin", "node"), "utf8"), theirs);
  } finally {
    m.done();
  }
});

/**
 * Releases on a `machine()`'s feed, made one at a time (`serve`): the curl stand-in gives the one served for the
 * release and a Node of `version` (bin/node, saying it) for the Node; a Node release names it in NODE_VERSION, a
 * MoonBit station's (`node: null`) has none and its reader. What is installed is the bundled installer, as a station
 * updating itself runs it, the release and its Node signed (a release with none signs a Node hash of zeros).
 */
function feed(m: ReturnType<typeof machine>, version = "24.21.0") {
  const dist = join(m.root, "node");
  mkdirSync(join(dist, "bin"), { recursive: true });
  writeFileSync(join(dist, "bin", "node"), `#!/bin/sh\necho v${version}\n`, { mode: 0o755 });
  execFileSync("tar", ["-czf", join(m.root, "node.tar.gz"), "-C", dist, "bin/node"]);
  const stub = join(m.root, "stub");
  writeFileSync(join(stub, "curl"), `#!/bin/sh\necho "curl $*" >> "$HOME/said"\nwhile [ $# -gt 1 ]; do\n  case "$1" in */releases/node/*) node=yes ;; esac\n  [ "$1" = -o ] && { [ -n "\${node:-}" ] && cp "${join(m.root, "node.tar.gz")}" "$2" || cp "${join(m.root, "release.tar.gz")}" "$2"; }\n  shift\ndone\n`, { mode: 0o755 });
  const serve = (name: string, node: string | null, installer?: string) => {
    const at = join(m.root, `release-${name}`);
    const release = join(at, "stillfail");
    mkdirSync(join(release, "bin"), { recursive: true });
    writeFileSync(join(release, "bin", "stillfail"), '#!/bin/sh\necho "stillfail $*" >> "$HOME/said"\n', { mode: 0o755 });
    writeFileSync(join(release, "VERSION"), `${name}\n`);
    if (node !== null) writeFileSync(join(release, "NODE_VERSION"), `${node}\n`);
    else {
      mkdirSync(join(release, "station"), { recursive: true });
      writeFileSync(join(release, "station", "stillfail-reader"), "#!/bin/sh\nexit 0\n", { mode: 0o755 });
    }
    if (installer !== undefined) writeFileSync(join(release, "bin", "install.zh.sh"), installer);
    execFileSync("tar", ["-czf", join(m.root, "release.tar.gz"), "-C", at, "stillfail"]);
    return {
      STILLFAIL_ORIGIN: "https://releases.test", STILLFAIL_INSTALL_LANG: "zh",
      STILLFAIL_RELEASE_SHA256: sha256Of(join(m.root, "release.tar.gz")),
      STILLFAIL_NODE_SHA256: node !== null ? sha256Of(join(dist, "bin", "node")) : "0".repeat(64),
    };
  };
  return { serve };
}

/// A running station as ps tells it, answering a handover (SIGUSR2) as `took` says: its new release taken over (the
/// launcher the same process, run/station.json saying it started anew) or failed (run/handoff-failed).
function running(m: ReturnType<typeof machine>, data: string, took: boolean): number {
  const fake = join(m.root, "stillfail-station");
  const listening = join(m.root, "listening");
  rmSync(listening, { force: true });
  const run = join(data, "run");
  writeFileSync(
    fake,
    `#!/bin/sh
n=0
say() { printf '{"pid": %s, "startedAt": %s, "handoff": 1, "drain": 1, "renew": 1}' $$ "$1" > "${run}/station.json"; }
took() { n=$((n + 1)); say $((1700000000000 + n)); }
failed() { echo "the new release did not start" > "${run}/handoff-failed"; }
mkdir -p "${run}"
say 1700000000000
trap ${took ? "took" : "failed"} USR2
touch "${listening}"
while :; do sleep 0.2; done
`,
    { mode: 0o755 },
  );
  // Not this process's child (the installer runs while this waits, so none is reaped here).
  const pid = Number(execFileSync("sh", ["-c", `"${fake}" </dev/null >/dev/null 2>&1 & echo $!`], { encoding: "utf8" }));
  while (!existsSync(listening)) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 50);
  return pid;
}

test("a Node release updated to the MoonBit station keeps its Node while that handover fails, prunes it once one took over, and a Node release installed again after it fetches and links its Node anew", () => {
  const m = machine();
  const data = join(m.home, ".stillfail");
  const app = join(data, "app");
  const nodeAt = join(data, "node", "v24.21.0", "bin", "node");
  const pids: number[] = [];
  try {
    mkdirSync(join(data, "mesh"), { recursive: true });
    writeFileSync(join(data, "mesh", "cloud.json"), '{"origin": "https://app.still.fail"}');
    const f = feed(m);
    const bundled = bundledInstallScript("zh");
    // a Node release, its Node fetched and linked
    const first = m.run([], f.serve("node-1", "24.21.0"), bundled);
    assert.equal(first.status, 0, first.out);
    assert.ok(existsSync(nodeAt));
    assert.equal(realpathSync(join(app, "node")), realpathSync(join(data, "node", "v24.21.0")));

    // the MoonBit station's release, whose handover fails: the release before back, on the Node it runs on
    pids.push(running(m, data, false));
    writeFileSync(join(m.home, "said"), "");
    const failed = m.run([], f.serve("mb-1", null), bundled);
    assert.equal(failed.status, 1, failed.out);
    assert.match(failed.out, /the new release did not start/);
    assert.equal(readFileSync(join(app, "VERSION"), "utf8"), "node-1\n", "the release before back in its place");
    assert.ok(existsSync(nodeAt), "its Node not pruned");
    assert.equal(realpathSync(join(app, "node")), realpathSync(join(data, "node", "v24.21.0")), "and still linked");
    assert.equal(readFileSync(join(app, "NODE_VERSION"), "utf8"), "24.21.0\n");
    assert.doesNotMatch(failed.said, /releases\/node\//, "no Node asked for");
    process.kill(pids.pop()!, "SIGKILL");

    // the same release taken over: no Node left once the station runs on none
    pids.push(running(m, data, true));
    rmSync(join(data, "run", "handoff-failed"), { force: true });
    const taken = m.run([], f.serve("mb-2", null), bundled);
    assert.equal(taken.status, 0, taken.out);
    assert.equal(readFileSync(join(app, "VERSION"), "utf8"), "mb-2\n");
    assert.ok(existsSync(join(app, "station", "stillfail-reader")));
    assert.throws(() => lstatSync(join(app, "node")), "no Node linked");
    assert.equal(existsSync(join(data, "node")), false, "the Node pruned");
    assert.ok(!existsSync(join(app + ".old")));

    // back to a Node release (a downgrade, the stable channel's of the day before): its Node fetched, checked and linked
    writeFileSync(join(m.home, "said"), "");
    const back = m.run([], f.serve("node-2", "24.21.0"), bundled);
    assert.equal(back.status, 0, back.out);
    assert.equal(readFileSync(join(app, "VERSION"), "utf8"), "node-2\n");
    assert.match(back.said, /curl .*\/releases\/node\/node-v24\.21\.0-darwin-arm64\.tar\.gz/);
    assert.ok(existsSync(nodeAt));
    assert.equal(realpathSync(join(app, "node")), realpathSync(join(data, "node", "v24.21.0")));
    assert.equal(execFileSync(join(app, "node", "bin", "node"), { encoding: "utf8" }), "v24.21.0\n");
    assert.deepEqual(readdirSync(join(data, "node")), ["v24.21.0"], "nothing half-made beside it");
  } finally {
    for (const pid of pids) process.kill(pid, "SIGKILL");
    m.done();
  }
});

test("a station from before the MoonBit station's release (17902afdac's bundled installer) updates to one with no Node: handed to the release's own installer, no Node fetched or linked, the Node before pruned", () => {
  const m = machine();
  const data = join(m.home, ".stillfail");
  const app = join(data, "app");
  try {
    mkdirSync(join(data, "mesh"), { recursive: true });
    writeFileSync(join(data, "mesh", "cloud.json"), '{"origin": "https://app.still.fail"}');
    // what a release from before left: its Node, kept beside the data
    mkdirSync(join(data, "node", "v24.21.0", "bin"), { recursive: true });
    writeFileSync(join(data, "node", "v24.21.0", "bin", "node"), "#!/bin/sh\necho v24.21.0\n", { mode: 0o755 });
    // The installer a station of then carries (`bundledInstallScript("zh")` at 17902afdac, the last main before #7109:
    // `git show 17902afdac:cloud/src/install.ts`), and the release's own (this one's, scripts/installers.ts), saying it ran.
    const before = readFileSync(join(import.meta.dirname, "install-17902afdac.zh.sh"), "utf8");
    assert.match(before, /prune_node\(\) \{\n {2}\[ -n "\$node_dir" \] \|\| return 0\n/, "the installer of then: no Node pruned when a release names none");
    const own = bundledInstallScript("zh").replace("set -eu\n", 'set -eu\necho "its own installer: $STILLFAIL_INSTALLER_HANDED" >> "$HOME/said"\n');
    const told = feed(m).serve("mb", null, own);
    const done = m.run([], told, before);
    assert.equal(done.status, 0, done.out);
    assert.match(done.said, /its own installer: 1/);
    assert.equal(done.said.match(/^curl /gm)?.length, 1, done.said);
    assert.doesNotMatch(done.said, /releases\/node\//, "no Node asked for");
    assert.equal(readFileSync(join(app, "VERSION"), "utf8"), "mb\n");
    assert.ok(existsSync(join(app, "station", "stillfail-reader")));
    for (const gone of ["node", "NODE_VERSION"]) assert.throws(() => lstatSync(join(app, gone)), gone);
    assert.equal(existsSync(join(data, "node")), false, "the Node of before taken away by the release's own installer");
  } finally {
    m.done();
  }
});

/**
 * The station `machine()` installed taken away by the repository's own command (bin/stillfail, put in place of the
 * release's stand-in): run as the person would (~/.local/bin/stillfail), with the machine's own stand-ins and Node on
 * its PATH. Asynchronous, so a test's Helper on its socket can answer meanwhile.
 */
function uninstall(m: ReturnType<typeof machine>, args: string[], env: Record<string, string> = {}): Promise<{ status: number | null; out: string; said: string }> {
  const app = join(m.home, ".stillfail", "app", "bin", "stillfail");
  if (existsSync(app)) writeFileSync(app, readFileSync(join(import.meta.dirname, "..", "..", "bin", "stillfail")), { mode: 0o755 });
  const command = existsSync(join(m.home, ".local", "bin", "stillfail")) ? join(m.home, ".local", "bin", "stillfail") : app;
  return new Promise((resolve) => {
    let out = "";
    const child = spawn("sh", [command, ...args], {
      env: { HOME: m.home, PATH: `${join(m.root, "stub")}:${dirname(process.execPath)}:/usr/bin:/bin:/usr/sbin:/sbin`, ...env } as unknown as NodeJS.ProcessEnv,
    });
    child.stdout.on("data", (d: Buffer) => (out += d));
    child.stderr.on("data", (d: Buffer) => (out += d));
    child.on("close", (status: number | null) => resolve({ status, out, said: existsSync(join(m.home, "said")) ? readFileSync(join(m.home, "said"), "utf8") : "" }));
  });
}

/** A launcher's stand-in running `data` (its command line names it, as the launcher's does), its pid as it says it. */
function launcher(data: string) {
  const child = spawn("sh", ["-c", "while :; do sleep 1; done", "stillfail-station", "run", "--data", data], { stdio: "ignore", env: { PATH: "/usr/bin:/bin" } as unknown as NodeJS.ProcessEnv });
  mkdirSync(join(data, "run"), { recursive: true });
  writeFileSync(join(data, "run", "station.json"), JSON.stringify({ pid: child.pid, version: "0.1.4321" }));
  return { child };
}

test("stillfail uninstall takes the station away for good, its data kept; installed again it is no longer said so and its service enabled", async () => {
  // (a short path: a Unix socket's is at most 104 bytes on a Mac)
  const m = machine("mac", true, "/tmp");
  const data = join(m.home, ".stillfail");
  try {
    assert.equal(m.run(["tok"]).status, 0);
    const plist = join(m.home, "Library", "LaunchAgents", "fail.still.station.plist");
    assert.ok(existsSync(plist));
    mkdirSync(join(data, "mesh"), { recursive: true });
    writeFileSync(join(data, "mesh", "cloud.json"), '{"origin": "https://app.still.fail"}');
    mkdirSync(join(data, "app.old"), { recursive: true });
    // its Helper, on its socket beside its token, saying what it was asked
    mkdirSync(join(data, "helper"), { recursive: true });
    writeFileSync(join(data, "helper", "token"), "tok-1\n");
    const asked: string[] = [];
    const helper = createServer((c) => c.on("data", (d) => { asked.push(String(d)); c.end('{"ok":true}\n'); }));
    await new Promise<void>((r) => helper.listen(join(data, "helper", "helper.sock"), r));
    const station = launcher(data);
    writeFileSync(join(m.home, "said"), "");
    // (no Node on its PATH: a release of the MoonBit station has none, and the Helper is told all the same)
    const done = await uninstall(m, ["uninstall"], { PATH: `${join(m.root, "stub")}:/usr/bin:/bin:/usr/sbin:/sbin` });
    helper.close();
    assert.equal(done.status, 0, done.out);
    assert.match(done.said, /^launchctl bootout gui\/\d+\/fail\.still\.station$/m);
    assert.match(done.said, /^launchctl enable gui\/\d+\/fail\.still\.station$/m);
    assert.ok(!existsSync(plist), "its service gone");
    // (ended before it said it was done: it waited for that)
    const running = station.child.exitCode === null && station.child.signalCode === null;
    if (running) station.child.kill();
    assert.ok(!running, "its launcher ended");
    assert.deepEqual(asked.map((a) => JSON.parse(a)), [{ token: "tok-1", op: "quit" }]);
    assert.throws(() => lstatSync(join(m.home, ".local", "bin", "stillfail")), "its command's link gone");
    for (const part of ["app", "app.old", "node", "helper", "run"]) assert.ok(!existsSync(join(data, part)), part);
    assert.ok(existsSync(join(data, "mesh", "cloud.json")), "its data kept");
    assert.ok(existsSync(join(data, "uninstalled")));
    assert.match(done.out, /kept in/);

    // installed again (the app's 启动, an update): no longer said taken away, its service enabled before it is loaded
    writeFileSync(join(m.home, "said"), "");
    const again = m.run();
    assert.equal(again.status, 0, again.out);
    assert.ok(!existsSync(join(data, "uninstalled")));
    const enable = again.said.search(/^launchctl enable gui\/\d+\/fail\.still\.station$/m);
    assert.ok(enable >= 0 && enable < again.said.indexOf("launchctl bootstrap"), again.said);
  } finally {
    m.done();
  }
});

test("stillfail uninstall --purge takes its data too; anything else is refused", async () => {
  const m = machine("mac", true, "/tmp");
  const data = join(m.home, ".stillfail");
  try {
    assert.equal(m.run(["tok"]).status, 0);
    const wrong = await uninstall(m, ["uninstall", "--all"]);
    assert.equal(wrong.status, 2, wrong.out);
    assert.match(wrong.out, /usage: stillfail uninstall \[--purge\]/);
    assert.ok(existsSync(join(data, "app")), "nothing taken");
    const more = await uninstall(m, ["uninstall", "--purge", "now"]);
    assert.equal(more.status, 2, more.out);
    const purged = await uninstall(m, ["uninstall", "--purge"]);
    assert.equal(purged.status, 0, purged.out);
    assert.ok(!existsSync(data));
    assert.ok(!existsSync(join(m.home, "Library", "LaunchAgents", "fail.still.station.plist")));
  } finally {
    m.done();
  }
});

test("stillfail uninstall of a data directory of its own leaves the person's station beside it alone", async () => {
  for (const os of ["mac", "linux"] as const) {
    const m = machine(os, true, "/tmp");
    try {
      // the person's own: installed as always (~/.stillfail, its service naming it)
      assert.equal(m.run(["tok"]).status, 0);
      const plist = join(m.home, "Library", "LaunchAgents", "fail.still.station.plist");
      const unit = join(m.home, ".config", "systemd", "user", "stillfail-station.service");
      const service = os === "mac" ? plist : unit;
      assert.ok(existsSync(service));
      const mine = launcher(join(m.home, ".stillfail"));
      // another's, apart: its release, its run
      const apart = join(m.root, "apart");
      mkdirSync(join(apart, "app", "bin"), { recursive: true });
      writeFileSync(join(apart, "app", "bin", "stillfail"), "");
      writeFileSync(join(m.home, "said"), "");
      const done = await uninstall(m, ["uninstall"], { STILLFAIL_DATA: apart });
      assert.equal(done.status, 0, done.out);
      assert.ok(existsSync(service), `${os}: the person's service left`);
      assert.doesNotMatch(done.said, /launchctl|systemctl/, os);
      assert.ok(existsSync(join(m.home, ".stillfail", "app")), `${os}: the person's release left`);
      assert.ok(lstatSync(join(m.home, ".local", "bin", "stillfail")).isSymbolicLink(), `${os}: the person's command left`);
      assert.equal(mine.child.exitCode, null, `${os}: the person's station still runs`);
      mine.child.kill();
      assert.ok(!existsSync(join(apart, "app")) && existsSync(join(apart, "uninstalled")), os);

      // its own (a Linux's): the service that runs it is taken away
      if (os === "linux") {
        writeFileSync(join(m.home, "said"), "");
        const own = await uninstall(m, ["uninstall"]);
        assert.equal(own.status, 0, own.out);
        assert.match(own.said, /^systemctl --user disable --now stillfail-station\.service$/m);
        assert.match(own.said, /^systemctl --user daemon-reload$/m);
        assert.ok(!existsSync(unit));
      }
    } finally {
      m.done();
    }
  }
});

/**
 * A machine's station installed and its data made up (a database, a session's files, a socket of its run), its
 * launchctl and systemctl saying what they were asked, the service started writing Node's word (run/health.json, now)
 * where `starts`, as a station that runs from its data does.
 */
async function moving(os: "mac" | "linux", starts = true) {
  const m = machine(os, true, "/tmp");
  assert.equal(m.run(["tok"]).status, 0);
  const data = join(m.home, ".stillfail");
  mkdirSync(join(data, "sessions", "chat", "c-1", "workspace"), { recursive: true });
  writeFileSync(join(data, "stillfail.db"), "the chats");
  writeFileSync(join(data, "sessions", "chat", "c-1", "workspace", "notes.md"), "kept");
  mkdirSync(join(data, "run"), { recursive: true });
  const sock = createServer();
  await new Promise<void>((r) => sock.listen(join(data, "run", "s.sock"), r));
  sock.close();
  const healthy = starts ? `printf '{"pid":1,"updatedAt":%s}\\n' "$(( $(date +%s) * 1000 + 1000 ))" > "$HOME/.stillfail/run/health.json"\n` : "";
  for (const [name, start] of [["launchctl", "bootstrap"], ["systemctl", "start"]]) {
    writeFileSync(join(m.root, "stub", name), `#!/bin/sh\necho "${name} $*" >> "$HOME/said"\n[ "$1" = print ] && exit 1\ncase "$*" in *${start}*) mkdir -p "$HOME/.stillfail/run"; ${healthy || ":"} ;; esac\nexit 0\n`, { mode: 0o755 });
  }
  return { m, data };
}

test("stillfail move takes the station's data to another disk, its name left a link to it, and back home again", async () => {
  for (const os of ["mac", "linux"] as const) {
    const { m, data } = await moving(os);
    try {
      const disk = join(m.root, "disk");
      mkdirSync(disk);
      const station = launcher(data);
      writeFileSync(join(m.home, "said"), "");
      const done = await uninstall(m, ["move", disk], { STILLFAIL_MOVE_APART: "1" });
      const running = station.child.exitCode === null && station.child.signalCode === null;
      if (running) station.child.kill();
      assert.equal(done.status, 0, done.out);
      assert.ok(!running, `${os}: what ran of its data stopped`);
      assert.equal(readlinkSync(data), join(realpathSync(disk), "stillfail"), os);
      assert.equal(readFileSync(join(data, "stillfail.db"), "utf8"), "the chats");
      assert.equal(readFileSync(join(disk, "stillfail", "sessions", "chat", "c-1", "workspace", "notes.md"), "utf8"), "kept");
      assert.ok(!existsSync(join(m.home, ".stillfail.moved")) && !existsSync(join(disk, "stillfail.moving")), `${os}: nothing left of the old place`);
      if (os === "mac") {
        assert.match(done.said, /^launchctl bootout gui\/\d+\/fail\.still\.station$/m);
        assert.match(done.said, /^launchctl bootstrap gui\/\d+ \S+fail\.still\.station\.plist$/m);
      } else {
        assert.match(done.said, /^systemctl --user stop stillfail-station\.service$/m);
        assert.match(done.said, /^systemctl --user start stillfail-station\.service$/m);
      }
      assert.match(done.out, /^100%$/m);
      assert.match(done.out, /moved to/);

      // moved again where it is: nothing done; to a folder holding one: refused
      assert.equal((await uninstall(m, ["move", disk], { STILLFAIL_MOVE_APART: "1" })).status, 0);
      const other = join(m.root, "other");
      mkdirSync(join(other, "stillfail"), { recursive: true });
      writeFileSync(join(other, "stillfail", "x"), "");
      const there = await uninstall(m, ["move", other], { STILLFAIL_MOVE_APART: "1" });
      assert.equal(there.status, 3, there.out);
      assert.match(there.out, /is there already/);

      // back home: a directory of its own again
      const back = await uninstall(m, ["move", m.home], { STILLFAIL_MOVE_APART: "1" });
      assert.equal(back.status, 0, back.out);
      assert.ok(lstatSync(data).isDirectory(), `${os}: home again`);
      assert.equal(readFileSync(join(data, "stillfail.db"), "utf8"), "the chats");
      assert.ok(!existsSync(join(disk, "stillfail")), `${os}: the disk's copy given back`);
    } finally {
      m.done();
    }
  }
});

test("stillfail move on the same disk renames it, nothing copied", async () => {
  // (each system's stat asked its way: GNU's -f is the file system's figures, its %d free inodes)
  for (const os of ["mac", "linux"] as const) {
    const { m, data } = await moving(os);
    try {
      const folder = join(m.root, "folder");
      mkdirSync(folder);
      const done = await uninstall(m, ["move", folder]);
      assert.equal(done.status, 0, done.out);
      assert.equal(readlinkSync(data), join(realpathSync(folder), "stillfail"), os);
      assert.doesNotMatch(done.out, /copying/, os);
      assert.equal(readFileSync(join(data, "stillfail.db"), "utf8"), "the chats");
    } finally {
      m.done();
    }
  }
});

test("a station that does not start from where its data was moved stays where it was", async () => {
  const { m, data } = await moving("mac", false);
  try {
    const disk = join(m.root, "disk");
    mkdirSync(disk);
    writeFileSync(join(m.home, "said"), "");
    const done = await uninstall(m, ["move", disk], { STILLFAIL_MOVE_APART: "1", STILLFAIL_MOVE_WAIT: "1" });
    assert.equal(done.status, 7, done.out);
    assert.match(done.out, /stays in/);
    assert.ok(lstatSync(data).isDirectory(), "its own directory, as before");
    assert.equal(readFileSync(join(data, "stillfail.db"), "utf8"), "the chats");
    assert.ok(!existsSync(join(disk, "stillfail")), "the copy removed");
    assert.equal(done.said.match(/launchctl bootstrap/g)?.length, 2, "started again where it was");
  } finally {
    m.done();
  }
});

test("stillfail move refuses what it cannot do, and uninstall --purge takes the data where it was moved", async () => {
  const { m, data } = await moving("linux");
  try {
    assert.equal((await uninstall(m, ["move", "disk"])).status, 2, "a path not whole");
    assert.equal((await uninstall(m, ["move", join(m.root, "none")])).status, 2, "no such folder");
    assert.equal((await uninstall(m, ["move", join(data, "sessions")])).status, 2, "inside its data");
    const apart = await uninstall(m, ["move", m.root], { STILLFAIL_DATA: join(m.root, "apart") });
    assert.equal(apart.status, 2, apart.out);
    assert.ok(lstatSync(data).isDirectory(), "nothing moved");
    const disk = join(m.root, "disk");
    mkdirSync(disk);
    assert.equal((await uninstall(m, ["move", disk], { STILLFAIL_MOVE_APART: "1" })).status, 0);
    const purged = await uninstall(m, ["uninstall", "--purge"]);
    assert.equal(purged.status, 0, purged.out);
    assert.ok(!existsSync(join(disk, "stillfail")) && !existsSync(data));
  } finally {
    m.done();
  }
});

/**
 * still.fail's station and monoid's beside it on one machine, each installed by its cloud's installer and each with
 * data of its own (a database saying whose), the repository's bin/stillfail in both releases; launchctl and systemctl
 * saying what they were asked, the service a start names writing Node's word (run/health.json, now) in its own data.
 */
async function both(os: "mac" | "linux") {
  const m = machine(os, true, "/tmp");
  assert.equal(m.run(["tok"]).status, 0);
  assert.equal(m.run(["tok"], {}, installScript("https://app.monoid.build")).status, 0);
  for (const product of ["stillfail", "monoid"]) {
    const data = join(m.home, `.${product}`);
    writeFileSync(join(data, "stillfail.db"), `${product}'s chats`);
    writeFileSync(join(data, "app", "bin", "stillfail"), readFileSync(join(import.meta.dirname, "..", "..", "bin", "stillfail")), { mode: 0o755 });
  }
  const healthy = `mkdir -p "$d/run"; printf '{"pid":1,"updatedAt":%s}\\n' "$(( $(date +%s) * 1000 + 1000 ))" > "$d/run/health.json"`;
  for (const [name, start] of [["launchctl", "bootstrap"], ["systemctl", "start"]]) {
    writeFileSync(join(m.root, "stub", name), `#!/bin/sh\necho "${name} $*" >> "$HOME/said"\n[ "$1" = print ] && exit 1\ncase "$*" in *${start}*monoid*) d=$HOME/.monoid; ${healthy} ;; *${start}*) d=$HOME/.stillfail; ${healthy} ;; esac\nexit 0\n`, { mode: 0o755 });
  }
  return m;
}

/** `command` (a path) run with `args` as the person would, the machine's stand-ins and Node on its PATH. */
function cli(m: ReturnType<typeof machine>, command: string, args: string[], env: Record<string, string> = {}): Promise<{ status: number | null; out: string; said: string }> {
  return new Promise((resolve) => {
    let out = "";
    const child = spawn("sh", [command, ...args], {
      env: { HOME: m.home, PATH: `${join(m.root, "stub")}:${dirname(process.execPath)}:/usr/bin:/bin:/usr/sbin:/sbin`, ...env } as unknown as NodeJS.ProcessEnv,
    });
    child.stdout.on("data", (d: Buffer) => (out += d));
    child.stderr.on("data", (d: Buffer) => (out += d));
    child.on("close", (status: number | null) => resolve({ status, out, said: existsSync(join(m.home, "said")) ? readFileSync(join(m.home, "said"), "utf8") : "" }));
  });
}

test("monoid's release command moves monoid's data and service, never still.fail's beside it, and brings it back", async () => {
  for (const os of ["mac", "linux"] as const) {
    // called by its path (as the app calls it), with no STILLFAIL_DATA and with the app's
    for (const env of [{}, { STILLFAIL_DATA: "" }]) {
      const m = await both(os);
      const monoid = join(m.home, ".monoid");
      const stillfail = join(m.home, ".stillfail");
      const given: Record<string, string> = "STILLFAIL_DATA" in env ? { STILLFAIL_DATA: monoid, STILLFAIL_MOVE_APART: "1" } : { STILLFAIL_MOVE_APART: "1" };
      const what = `${os}, ${"STILLFAIL_DATA" in env ? "STILLFAIL_DATA=~/.monoid" : "no STILLFAIL_DATA"}`;
      const mine = launcher(stillfail);
      try {
        const disk = join(m.root, "disk");
        mkdirSync(disk);
        writeFileSync(join(m.home, "said"), "");
        const command = join(monoid, "app", "bin", "stillfail");
        const done = await cli(m, command, ["move", disk], given);
        assert.equal(done.status, 0, `${what}: ${done.out}`);
        assert.equal(readlinkSync(monoid), join(realpathSync(disk), "monoid"), what);
        assert.equal(readFileSync(join(monoid, "stillfail.db"), "utf8"), "monoid's chats", what);
        assert.ok(lstatSync(stillfail).isDirectory(), `${what}: still.fail's data where it was`);
        assert.equal(readFileSync(join(stillfail, "stillfail.db"), "utf8"), "stillfail's chats", what);
        assert.equal(mine.child.exitCode, null, `${what}: still.fail's station still runs`);
        if (os === "mac") {
          assert.match(done.said, /^launchctl bootout gui\/\d+\/build\.monoid\.station$/m, what);
          assert.match(done.said, /^launchctl bootstrap gui\/\d+ \S+build\.monoid\.station\.plist$/m, what);
          assert.doesNotMatch(done.said, /fail\.still\.station/, what);
        } else {
          assert.match(done.said, /^systemctl --user stop monoid-station\.service$/m, what);
          assert.match(done.said, /^systemctl --user start monoid-station\.service$/m, what);
          assert.doesNotMatch(done.said, /stillfail-station/, what);
        }

        // back home, called by the same path, which now runs through the link to the disk
        writeFileSync(join(m.home, "said"), "");
        const back = await cli(m, command, ["move", m.home], given);
        assert.equal(back.status, 0, `${what}: ${back.out}`);
        assert.ok(lstatSync(monoid).isDirectory(), `${what}: home again`);
        assert.equal(readFileSync(join(monoid, "stillfail.db"), "utf8"), "monoid's chats", what);
        assert.ok(!existsSync(join(disk, "monoid")), `${what}: the disk's copy given back`);
        assert.equal(readFileSync(join(stillfail, "stillfail.db"), "utf8"), "stillfail's chats", what);
        assert.doesNotMatch(back.said, /fail\.still\.station|stillfail-station/, what);
        assert.equal(mine.child.exitCode, null, `${what}: still.fail's station still runs`);
      } finally {
        mine.child.kill();
        m.done();
      }
    }
  }
});

test("monoid's command with its data on a disk not connected, or with still.fail's named, never moves still.fail's", async () => {
  const m = await both("mac");
  try {
    const monoid = join(m.home, ".monoid");
    const stillfail = join(m.home, ".stillfail");
    const disk = join(m.root, "disk");
    mkdirSync(disk);
    // its release's command with still.fail's STILLFAIL_DATA (an agent of still.fail's station's): refused
    const crossed = await cli(m, join(monoid, "app", "bin", "stillfail"), ["move", disk], { STILLFAIL_DATA: stillfail, STILLFAIL_MOVE_APART: "1" });
    assert.equal(crossed.status, 2, crossed.out);
    assert.ok(lstatSync(stillfail).isDirectory() && lstatSync(monoid).isDirectory(), "nothing moved");
    rmSync(monoid, { recursive: true });
    symlinkSync(join(m.root, "unplugged", "monoid"), monoid);
    // (its command where its release is not: a clone's, linked as monoid)
    mkdirSync(join(m.root, "clone", "bin"), { recursive: true });
    writeFileSync(join(m.root, "clone", "bin", "monoid"), readFileSync(join(import.meta.dirname, "..", "..", "bin", "stillfail")), { mode: 0o755 });
    writeFileSync(join(m.home, "said"), "");
    const done = await cli(m, join(m.root, "clone", "bin", "monoid"), ["move", disk], { STILLFAIL_MOVE_APART: "1" });
    assert.equal(done.status, 8, done.out);
    assert.match(done.out, /not connected/);
    assert.ok(lstatSync(stillfail).isDirectory(), "still.fail's data where it was");
    assert.equal(readFileSync(join(stillfail, "stillfail.db"), "utf8"), "stillfail's chats");
    assert.ok(!existsSync(join(disk, "stillfail")) && !existsSync(join(disk, "monoid")), "nothing copied");
    assert.doesNotMatch(done.said, /launchctl|systemctl/);
  } finally {
    m.done();
  }
});

test("monoid's release command uninstalls monoid's station alone, still.fail's beside it left as it was", async () => {
  for (const os of ["mac", "linux"] as const) {
    const m = await both(os);
    const monoid = join(m.home, ".monoid");
    const stillfail = join(m.home, ".stillfail");
    const mine = launcher(stillfail);
    try {
      writeFileSync(join(m.home, "said"), "");
      const done = await cli(m, join(monoid, "app", "bin", "stillfail"), ["uninstall"]);
      assert.equal(done.status, 0, `${os}: ${done.out}`);
      assert.ok(!existsSync(join(monoid, "app")) && existsSync(join(monoid, "uninstalled")), `${os}: monoid's taken away, its data kept`);
      assert.ok(!existsSync(join(m.home, ".local", "bin", "monoid")), `${os}: monoid's command gone`);
      assert.ok(existsSync(join(stillfail, "app")) && !existsSync(join(stillfail, "uninstalled")), `${os}: still.fail's release left`);
      assert.ok(lstatSync(join(m.home, ".local", "bin", "stillfail")).isSymbolicLink(), `${os}: still.fail's command left`);
      assert.equal(mine.child.exitCode, null, `${os}: still.fail's station still runs`);
      if (os === "mac") {
        assert.match(done.said, /^launchctl bootout gui\/\d+\/build\.monoid\.station$/m);
        assert.doesNotMatch(done.said, /fail\.still\.station|org\.3720\.ember/);
        assert.ok(!existsSync(join(m.home, "Library", "LaunchAgents", "build.monoid.station.plist")));
        assert.ok(existsSync(join(m.home, "Library", "LaunchAgents", "fail.still.station.plist")));
      } else {
        assert.match(done.said, /^systemctl --user disable --now monoid-station\.service$/m);
        assert.doesNotMatch(done.said, /stillfail-station/);
        assert.ok(existsSync(join(m.home, ".config", "systemd", "user", "stillfail-station.service")));
      }
    } finally {
      mine.child.kill();
      m.done();
    }
  }
});

/** The service files of `os` under `m`'s home: launchd's plist or systemd's unit, by product. */
function services(m: ReturnType<typeof machine>, os: "mac" | "linux") {
  const at = (product: "stillfail" | "monoid") =>
    os === "mac"
      ? join(m.home, "Library", "LaunchAgents", `${product === "stillfail" ? "fail.still" : "build.monoid"}.station.plist`)
      : join(m.home, ".config", "systemd", "user", `${product}-station.service`);
  return { stillfail: at("stillfail"), monoid: at("monoid") };
}

test("a data directory of its own moved to monoid's cloud keeps its still.fail service: no monoid service beside it, and an update hands over", () => {
  for (const os of ["mac", "linux"] as const) {
    const m = machine(os);
    const data = join(m.root, "station");
    const svc = services(m, os);
    let pid = 0;
    try {
      // Monoid Machine's: /data/station, run by stillfail-station.service
      assert.equal(m.run(["tok"], { STILLFAIL_DATA: data }).status, 0);
      assert.ok(existsSync(svc.stillfail), os);
      mkdirSync(join(data, "mesh"), { recursive: true });
      writeFileSync(join(data, "mesh", "cloud.json"), '{"origin": "https://app.monoid.build"}');
      writeFileSync(join(m.home, "said"), "");
      const update = m.run([], { STILLFAIL_DATA: data, STILLFAIL_ORIGIN: "https://app.monoid.build" }, installScript("https://app.monoid.build"));
      assert.equal(update.status, 0, `${os}: ${update.out}`);
      assert.ok(existsSync(svc.stillfail), `${os}: its service kept`);
      assert.ok(!existsSync(svc.monoid), `${os}: no monoid service for the same data`);
      assert.throws(() => lstatSync(join(m.home, ".local", "bin", "monoid")), `${os}: no monoid command`);
      assert.equal(readlinkSync(join(m.home, ".local", "bin", "stillfail")), join(data, "app", "bin", "stillfail"));
      if (os === "mac") assert.match(update.said, /^launchctl bootstrap gui\/\d+ \S+fail\.still\.station\.plist$/m);
      else assert.match(update.said, /^systemctl --user restart stillfail-station\.service$/m);
      assert.doesNotMatch(update.said, /build\.monoid|monoid-station/, os);

      // running, its service unchanged: the next update hands over in place
      writeFileSync(join(data, "app", "VERSION"), "old\n");
      pid = running(m, data, true);
      writeFileSync(join(m.home, "said"), "");
      const handed = m.run([], { STILLFAIL_DATA: data }, installScript("https://app.monoid.build"));
      assert.equal(handed.status, 0, `${os}: ${handed.out}`);
      assert.match(handed.out, /已更新|updated/i, os);
      assert.doesNotMatch(handed.said, /launchctl (bootout|bootstrap)|systemctl --user (stop|restart|disable)/, `${os}: not restarted`);
      assert.ok(!existsSync(svc.monoid), os);
    } finally {
      if (pid) process.kill(pid, "SIGKILL");
      m.done();
    }
  }
});

test("a data directory run by both products' services is given back its still.fail service alone, even on the release it runs", () => {
  for (const os of ["mac", "linux"] as const) {
    const m = machine(os);
    const data = join(m.root, "station");
    const svc = services(m, os);
    let pid = 0;
    try {
      assert.equal(m.run(["tok"], { STILLFAIL_DATA: data }).status, 0);
      mkdirSync(join(data, "mesh"), { recursive: true });
      writeFileSync(join(data, "mesh", "cloud.json"), '{"origin": "https://app.monoid.build"}');
      // as an installer from before left it: monoid's service for the same data, and monoid's command linked to it
      writeFileSync(svc.monoid, readFileSync(svc.stillfail, "utf8").replace("fail.still.station", "build.monoid.station"));
      symlinkSync(join(data, "app", "bin", "stillfail"), join(m.home, ".local", "bin", "monoid"));
      pid = running(m, data, true);
      writeFileSync(join(m.home, "said"), "");
      const update = m.run([], { STILLFAIL_DATA: data, STILLFAIL_NO_DRAIN: "1" }, installScript("https://app.monoid.build"));
      assert.equal(update.status, 0, `${os}: ${update.out}`);
      assert.ok(existsSync(svc.stillfail), `${os}: its service kept`);
      assert.ok(!existsSync(svc.monoid), `${os}: monoid's taken away`);
      assert.throws(() => lstatSync(join(m.home, ".local", "bin", "monoid")), `${os}: monoid's command gone`);
      if (os === "mac") {
        assert.match(update.said, /^launchctl bootout gui\/\d+\/build\.monoid\.station$/m);
        assert.match(update.said, /^launchctl bootstrap gui\/\d+ \S+fail\.still\.station\.plist$/m);
        assert.doesNotMatch(update.said, /bootstrap \S+ \S+build\.monoid/);
      } else {
        assert.match(update.said, /^systemctl --user disable --now monoid-station\.service$/m);
        assert.match(update.said, /^systemctl --user restart stillfail-station\.service$/m);
        assert.doesNotMatch(update.said, /(restart|enable) monoid-station/);
      }
    } finally {
      if (pid) process.kill(pid, "SIGKILL");
      m.done();
    }
  }
});

test("a data directory of its own run by monoid's service alone keeps it when updated from still.fail's cloud", () => {
  const m = machine("linux");
  const data = join(m.root, "station");
  const svc = services(m, "linux");
  try {
    assert.equal(m.run(["tok"], { STILLFAIL_DATA: data }, installScript("https://app.monoid.build")).status, 0);
    assert.ok(existsSync(svc.monoid) && !existsSync(svc.stillfail));
    mkdirSync(join(data, "mesh"), { recursive: true });
    writeFileSync(join(data, "mesh", "cloud.json"), '{"origin": "https://app.still.fail"}');
    writeFileSync(join(m.home, "said"), "");
    const update = m.run([], { STILLFAIL_DATA: data });
    assert.equal(update.status, 0, update.out);
    assert.ok(existsSync(svc.monoid) && !existsSync(svc.stillfail), "no still.fail service beside it");
    assert.match(update.said, /^systemctl --user restart monoid-station\.service$/m);
    assert.doesNotMatch(update.said, /stillfail-station\.service/);
  } finally {
    m.done();
  }
});

test("~/.stillfail updated from monoid's cloud keeps still.fail's service, monoid's own station beside it left as it was", () => {
  for (const os of ["mac", "linux"] as const) {
    const m = machine(os);
    const stillfail = join(m.home, ".stillfail");
    const svc = services(m, os);
    try {
      assert.equal(m.run(["tok"]).status, 0);
      assert.equal(m.run(["tok"], {}, installScript("https://app.monoid.build")).status, 0);
      const monoidService = readFileSync(svc.monoid, "utf8");
      mkdirSync(join(stillfail, "mesh"), { recursive: true });
      writeFileSync(join(stillfail, "mesh", "cloud.json"), '{"origin": "https://app.monoid.build"}');
      writeFileSync(join(m.home, "said"), "");
      const update = m.run([], { STILLFAIL_DATA: stillfail }, installScript("https://app.monoid.build"));
      assert.equal(update.status, 0, `${os}: ${update.out}`);
      assert.match(readFileSync(svc.stillfail, "utf8"), new RegExp(stillfail.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")), os);
      assert.equal(readFileSync(svc.monoid, "utf8"), monoidService, `${os}: monoid's service as it was`);
      assert.equal(readlinkSync(join(m.home, ".local", "bin", "monoid")), join(m.home, ".monoid", "app", "bin", "stillfail"));
      assert.doesNotMatch(update.said, /build\.monoid|monoid-station/, os);
    } finally {
      m.done();
    }
  }
});

test("stillfail uninstall of a data directory of its own takes away whichever product's service runs it, never the person's own", async () => {
  const m = machine("linux", true, "/tmp");
  try {
    assert.equal(m.run(["tok"]).status, 0);
    const svc = services(m, "linux");
    const apart = join(m.root, "apart");
    mkdirSync(join(apart, "app", "bin"), { recursive: true });
    writeFileSync(join(apart, "app", "bin", "stillfail"), "");
    writeFileSync(svc.monoid, readFileSync(svc.stillfail, "utf8").replaceAll(join(m.home, ".stillfail"), apart));
    symlinkSync(join(apart, "app", "bin", "stillfail"), join(m.home, ".local", "bin", "monoid"));
    writeFileSync(join(m.home, "said"), "");
    const done = await uninstall(m, ["uninstall"], { STILLFAIL_DATA: apart });
    assert.equal(done.status, 0, done.out);
    assert.match(done.said, /^systemctl --user disable --now monoid-station\.service$/m);
    assert.doesNotMatch(done.said, /stillfail-station/);
    assert.ok(!existsSync(svc.monoid) && existsSync(svc.stillfail));
    assert.throws(() => lstatSync(join(m.home, ".local", "bin", "monoid")));
    assert.ok(lstatSync(join(m.home, ".local", "bin", "stillfail")).isSymbolicLink(), "the person's command left");
  } finally {
    m.done();
  }
});
