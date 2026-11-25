// The station's and its runtimes' versions and updating them, with fake release
// servers, fake installers and fake npm/vp/curl commands in temporary directories: nothing real is installed or read.
import assert from "node:assert/strict";
import { isDeepStrictEqual } from "node:util";
import { execFile, execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, readlinkSync, realpathSync, symlinkSync, writeFileSync } from "node:fs";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { describe, test } from "node:test";
import { setTimeout as sleep } from "node:timers/promises";
import { ConfigFile } from "../src/ops/config.ts";
import { tr } from "../src/ops/i18n.ts";
import { hearLines, type Line } from "../src/ops/log.ts";
import { type Env, type Found, howToInstallSoon, howToUpdateSoon, findCommandSoon, ownNode, pinNpmVersion, run, runLines, Unable, kindCommand, kindPackage } from "../src/updates/runtimes.ts";
import { hold } from "../src/updates/holds.ts";
import { Updates, type UpdatesOptions } from "../src/updates/updates.ts";
import { versionTools } from "../src/tools/version.ts";
import { WINDOWS, platform as machine } from "../src/platform/index.ts";
import { windowsUpdateScript, wingetPackage } from "../src/platform/windows.ts";
import {
  channelOf, curlPercent, downloading, feed, INSTALLING, newer, offer, platform as npmPlatform, releaseChannel, say, stationDownloadPercent, stationVersion, stepOf, tail, versionIn,
} from "../src/updates/versions.ts";
import { setChannelIn } from "../src/updates/channel.ts";
import { exe, launcher, script as stand_in } from "./accounts-fakes.ts";
import { OTHER, SHA_A, SHA_B, feedOf, nextRelease, programBytes, signed as signedWords, trusted, withDeltas, withEarlier } from "./release-fakes.ts";
import { settle, testClock } from "./hub-fakes.ts";

delete process.env.STILLFAIL_CONFIG;

const temp = () => realpathSync(mkdtempSync(join(tmpdir(), "stillfail-updates-")));
/// Looks every 20 ms until `f` holds: what real processes, files and sockets do has no event here. No deadline (it
/// comes, however slow the machine, or the test times out); cancellation stops its wait and releases its timer.
async function until(_what: string, f: () => boolean, signal: AbortSignal) {
  signal.throwIfAborted();
  while (!f()) await sleep(20, undefined, { signal });
}
/// An executable script at `path` (a shell one by the launcher the stand-ins share: see accounts-fakes.ts).
const script = (path: string, text: string) => {
  mkdirSync(dirname(path), { recursive: true });
  stand_in(path, text);
};

/// A station installed by the installer (<data>/app, BUILD `build`, from `channel`, carrying `installer` as its
/// bin/install.zh.sh), in a cloud that answers nothing; it takes the tests' release key.
function installed(data: string, build: string, channel: string | null, more: Partial<UpdatesOptions> = {}, installer?: string): Updates {
  const app = join(data, "app");
  mkdirSync(join(app, "bin"), { recursive: true });
  writeFileSync(join(app, "BUILD"), build);
  if (channel !== null) writeFileSync(join(app, "CHANNEL"), channel);
  if (installer !== undefined) writeFileSync(join(app, "bin", "install.zh.sh"), installer);
  const updates = new Updates({
    app, data, config: new ConfigFile(data), origin: () => "http://127.0.0.1:1", registry: "http://127.0.0.1:1", devinManifest: "http://127.0.0.1:1", env: { PATH: "/nowhere" },
    timing: { followLook: 200 }, trusted, ...more,
  });
  return updates;
}

const station = (u: Updates) => u.get("zh")[0]!;

/// A PATH of `bin` and the system's commands.
const withSystem = (bin: string) => (WINDOWS ? `${bin};${process.env.SystemRoot ?? "C:\\Windows"}\\System32` : `${bin}:/usr/bin:/bin`);

/// A server answering `routes` (path → status and body, or a function of the request's path and query).
type Said = { status?: number; type?: string; body: string | Buffer } | null;
async function serve(routes: (path: string, search: string) => Said | Promise<Said>): Promise<[string, Server]> {
  const server = createServer(async (req, res) => {
    const url = new URL(req.url ?? "/", "http://x");
    const said = await routes(url.pathname, url.search);
    if (said === null) return void res.writeHead(404).end("no");
    const body = typeof said.body === "string" ? Buffer.from(said.body) : said.body;
    res.writeHead(said.status ?? 200, { "content-type": said.type ?? "application/json", "content-length": body.length }).end(body);
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  return [`http://127.0.0.1:${(server.address() as AddressInfo).port}`, server];
}

/// A still.fail cloud with a release out (`latest` on the stable feed, signed with the tests' key; `feed` instead when
/// given), and the installer the station's release carries (the last of what this gives), playing the real one's part
/// on a temporary data directory: says its steps and what it was told, puts the new BUILD in the release, ends 0. Its
/// download goes on until `finish` is called (asking the cloud for /download, which answers then); unless `held`, it
/// goes on at once. Handed an archive (STILLFAIL_ARCHIVE, a delta's), it keeps a copy in <data>/handed and takes it as
/// the real one does (its directory removed). `files`: more the cloud serves under /releases/.
async function cloudWithRelease(latest: string, build: string, held = false, feed?: object, files: Record<string, () => Said | Promise<Said>> = {}): Promise<[string, Server, string[], () => void, string]> {
  const asked: string[] = [];
  let finish = () => {};
  const finished = held ? new Promise<void>((r) => (finish = r)) : Promise.resolve();
  let origin = "";
  const installer = () => `#!/bin/sh
set -eu
run="$STILLFAIL_DATA/run"
printf 'download\\n' > "$run/update.step"
echo "### 50.0%"
printf '%s %s\\n' "$STILLFAIL_CHANNEL" "$STILLFAIL_DATA" > "$STILLFAIL_DATA/installer-saw"
printf '%s %s %s %s\\n' "$STILLFAIL_ORIGIN" "$STILLFAIL_RELEASE_SHA256" "$STILLFAIL_NODE_SHA256" "$STILLFAIL_INSTALL_LANG" >> "$STILLFAIL_DATA/installer-saw"
echo ran >> "$STILLFAIL_DATA/installer-ran"
if [ -n "\${STILLFAIL_ARCHIVE:-}" ]; then
  case "$STILLFAIL_ARCHIVE" in */stillfail-handed.*/stillfail.tar.gz) ;; *) echo "not where the installer takes one: $STILLFAIL_ARCHIVE" >&2; exit 1 ;; esac
  cp "$STILLFAIL_ARCHIVE" "$STILLFAIL_DATA/handed"
  rm -rf "$(dirname "$STILLFAIL_ARCHIVE")"
fi
curl -fsS "${origin}/download" > /dev/null
printf 'handoff\\n' > "$run/update.step"
printf '${build}\\n' > "$STILLFAIL_DATA/app/BUILD"
`;
  const [base, server] = await serve(async (path, search) => {
    asked.push(path + search);
    const file = path.startsWith("/releases/") ? files[path.slice("/releases/".length)] : undefined;
    if (file) return file();
    if (path === "/releases/station.json") return { body: JSON.stringify(feed ?? feedOf(Number(latest.split(".").at(-1)))) };
    if (path === "/download") return finished.then(() => ({ type: "text/plain", body: "" }));
    return null;
  });
  origin = base;
  return [origin, server, asked, finish, installer()];
}

/// A registry with Codex 0.47.0 out, its build for this machine downloadable; and a bin with a fake npm that records
/// what it is asked and, asked to install, puts a `codex` saying `version` beside itself (none: it installs nothing).
async function codexWorld(version: string | null): Promise<[string, Server, string, string]> {
  const tarball = Buffer.alloc(300_000, 1);
  let base = "";
  const [registry, server] = await serve((path) => {
    if (path === "/@openai/codex/latest") return { body: JSON.stringify({ version: "0.47.0" }) };
    if (path.startsWith("/@openai/codex/0.47.0-")) return { body: JSON.stringify({ dist: { tarball: `${base}/codex.tgz` } }) };
    if (path === "/codex.tgz") return { type: "application/octet-stream", body: tarball };
    if (path === "/@anthropic-ai/claude-code/latest") return { body: JSON.stringify({ version: "2.1.300" }) };
    return null;
  });
  base = registry;
  const bin = join(temp(), "bin");
  const said = join(dirname(bin), "npm-asked");
  // On Windows what is installed is a .cmd (as npm's shims are), written by Git's sh: its paths with /.
  const [b, s] = [bin, said].map((p) => p.replaceAll("\\", "/"));
  const codex = WINDOWS ? `printf '@echo codex-cli ${version}\\r\\n' > "${b}/codex.cmd"` : `printf '#!/bin/sh\\necho "codex-cli ${version}"\\n' > "${b}/codex.sh"; /bin/ln "${launcher()}" "${b}/codex"`;
  script(join(bin, "npm"), `#!/bin/sh
echo "$*" >> "${s}"
if [ "$1" = install ]; then
  echo "==> Downloading codex"
  ${version === null ? ":" : codex}
  echo "added 1 package"
fi
exit 0
`);
  return [registry, server, bin, said];
}

const found = (real: string): Found => ({ onPath: "/nowhere/bin/x", real });

describe("updates", { concurrency: true }, () => {
  test("a cancelled update wait lets its test end", async () => {
    const controller = new AbortController();
    let satisfied = false;
    const waiting = until("a condition that has not happened", () => satisfied, controller.signal);
    controller.abort();
    const result = await Promise.race([
      waiting.then(() => "resolved", (error: Error) => error.name),
      new Promise<string>((resolve) => setImmediate(() => resolve("still waiting"))),
    ]);
    satisfied = true;
    await waiting.catch(() => {});
    assert.equal(result, "AbortError");
  });

  test("an install says where it is as it goes", async () => {
    const env: Env = { PATH: "/usr/bin:/bin" };
    const steps: string[] = [];
    const program = "console.log('==> Downloading https://x'); console.log('==> Pouring codex'); console.error('Warning: x'); process.exitCode = 3";
    const [ok, said, code] = await runLines(process.execPath, ["-e", program], env, 10_000, (line) => {
      const s = stepOf(line);
      if (s) steps.push(say(s, "zh"));
    });
    assert.deepEqual([ok, code], [false, 3]);
    assert.deepEqual(steps, ["正在下载", say(INSTALLING, "zh")]);
    // Both streams kept (their order between them is not known).
    assert.ok(said.includes("==> Pouring codex") && said.includes("Warning: x"));
    assert.deepEqual(stepOf("Setting up Claude Code..."), INSTALLING);
    assert.equal(stepOf("added 2 packages in 4s"), null);
    const [a, p] = downloading("0.159.3", 60_000_000, 133_847_481);
    assert.deepEqual([say(a, "zh"), p], ["正在下载 0.159.3：60/134 MB", 44]);
    const [b, q] = downloading("0.159.3", 60_000_000, null);
    assert.deepEqual([say(b, "zh"), q], ["正在下载 0.159.3：已下载 60 MB", null]);
  });

  test("versions compare number by number", () => {
    assert.ok(newer("2.1.9", "2.1.10"));
    assert.ok(!newer("2.1.10", "2.1.9"));
    assert.ok(!newer("0.1.1200", "0.1.1200"));
    assert.ok(newer("0.46.0", "0.47.0-alpha.1"));
  });

  test("a version is read from what the command says", () => {
    assert.equal(versionIn("2.1.284 (Claude Code)"), "2.1.284");
    assert.equal(versionIn("codex-cli 0.46.0\n"), "0.46.0");
    assert.equal(versionIn("nothing here"), null);
  });

  test("a release says its version and a clone none", () => {
    const dir = temp();
    assert.equal(stationVersion(dir), undefined);
    writeFileSync(join(dir, "BUILD"), "1234\n");
    assert.equal(stationVersion(dir), "0.1.1234");
  });

  test("the latest comes from the channel's feed and a station is on the channel it was installed from", () => {
    assert.equal(feed("stable", "https://app.still.fail"), "https://app.still.fail/releases/station.json");
    assert.equal(feed("beta", "https://app.still.fail"), "https://app.still.fail/releases/station-beta.json");
    const dir = temp();
    // An install from before channels, and a config that says none: stable.
    assert.equal(releaseChannel(dir), null);
    assert.equal(channelOf({}, dir), "stable");
    assert.equal(channelOf({ updateChannel: "nonsense" }, dir), "stable");
    // Installed from the beta (its installer wrote CHANNEL before the station ran): on it, until the config says otherwise.
    const beta = temp();
    writeFileSync(join(beta, "CHANNEL"), "beta\n");
    assert.equal(channelOf({}, beta), "beta");
    assert.equal(channelOf({ updateChannel: "stable" }, beta), "stable");
    assert.equal(channelOf({ updateChannel: "beta" }, beta), "beta");
  });

  test("an older version is offered only back from the beta", () => {
    // Newer is newer on either channel.
    assert.deepEqual(offer("0.1.10", "0.1.12", "stable", "stable"), [true, false]);
    assert.deepEqual(offer("0.1.10", "0.1.12", "beta", "stable"), [true, false]);
    // A stable station never goes back by itself, nor a beta one to an older beta.
    assert.deepEqual(offer("0.1.12", "0.1.10", "stable", "stable"), [false, false]);
    assert.deepEqual(offer("0.1.12", "0.1.10", "beta", "beta"), [false, false]);
    // Switched back from the beta: the older stable release is offered, as going back.
    assert.deepEqual(offer("0.1.12", "0.1.10", "stable", "beta"), [false, true]);
    // The same build (a beta promoted): nothing.
    assert.deepEqual(offer("0.1.12", "0.1.12", "stable", "beta"), [false, false]);
    assert.deepEqual(offer(null, "0.1.10", "stable", "beta"), [false, false]);
    assert.deepEqual(offer("0.1.12", null, "stable", "beta"), [false, false]);
    // 0.<m>.<n> by n alone: a release branch's stable 0.35.11 (m one more) is not newer than the beta's 0.34.12.
    assert.deepEqual(offer("0.34.10", "0.35.12", "stable", "stable"), [true, false]);
    assert.deepEqual(offer("0.1.10", "0.34.12", "stable", "stable"), [true, false]);
    assert.deepEqual(offer("0.34.12", "0.35.11", "beta", "beta"), [false, false]);
    assert.deepEqual(offer("0.34.12", "0.35.11", "stable", "beta"), [false, true]);
  });

  test("an update started before a handover is followed to its end", async (t) => {
    const dir = temp();
    const runDir = join(dir, "run");
    mkdirSync(runDir, { recursive: true });
    // Started by the release this one took over from, which was 0.1.1299; the installer is handing over.
    writeFileSync(join(runDir, "update.started"), JSON.stringify({ at: Date.now(), from: "0.1.1299" }));
    writeFileSync(join(runDir, "update.step"), "handoff\n");
    const updates = installed(dir, "1300", null);
    t.after(() => updates.close());
    updates.countRunning(() => 2);
    await updates.followStarted();
    assert.deepEqual([station(updates).state, station(updates).progress], ["updating", "正在交接给新版本（agent 不中断）"]);
    // Had it had to restart: what the drain waits on.
    writeFileSync(join(runDir, "update.step"), "drain\n");
    await until("draining", () => station(updates).progress === "等待 2 个 agent 完成本轮后重启（新消息将排队）", t.signal);
    writeFileSync(join(runDir, "update.step"), "handoff\n");
    writeFileSync(join(runDir, "update.exit"), "0\n");
    await until("done", () => station(updates).state === "idle", t.signal);
    const line = station(updates);
    assert.deepEqual([line.state, line.progress, line.done], ["idle", undefined, "已更新到 0.1.1300，agent 未中断"]);
    assert.ok(!existsSync(join(runDir, "update.started")) && !existsSync(join(runDir, "update.step")));
    // Read again (the next check), it still says so; and in English to an English page.
    await updates.check();
    assert.equal(station(updates).done, "已更新到 0.1.1300，agent 未中断");
    assert.equal(updates.get("en")[0]!.done?.includes("0.1.1300"), true);
  });

  test("an update started here while the one before this process is looked for is the one followed", async (t) => {
    const dir = temp();
    const runDir = join(dir, "run");
    mkdirSync(runDir, { recursive: true });
    // What an update started here wrote, read by the look for one started before (it may end and be removed meanwhile).
    writeFileSync(join(runDir, "update.started"), JSON.stringify({ at: Date.now() - 1000, from: "0.1.1299" }));
    writeFileSync(join(runDir, "update.step"), "handoff\n");
    writeFileSync(join(runDir, "update.exit"), "0\n");
    const updates = installed(dir, "1300", null);
    t.after(() => updates.close());
    const before = updates.followStarted();
    // Started here as that is read, and ended: its files removed.
    await updates.follow({ at: Date.now(), from: "0.1.1299" });
    assert.deepEqual([station(updates).state, station(updates).done], ["idle", "已更新到 0.1.1300，agent 未中断"]);
    await before;
    assert.deepEqual([station(updates).state, station(updates).done], ["idle", "已更新到 0.1.1300，agent 未中断"], "not followed again from what was read");
  });

  test("an update started too long ago is not followed", async (t) => {
    const dir = temp();
    const runDir = join(dir, "run");
    mkdirSync(runDir, { recursive: true });
    writeFileSync(join(runDir, "update.started"), JSON.stringify({ at: Date.now() - 21 * 60_000, from: "0.1.1299" }));
    writeFileSync(join(runDir, "update.step"), "drain\n");
    const updates = installed(dir, "1300", null);
    t.after(() => updates.close());
    await updates.followStarted();
    assert.equal(station(updates).state, "idle");
    assert.ok(!existsSync(join(runDir, "update.started")) && !existsSync(join(runDir, "update.step")));
  });

  test("the installer's download percent reads complete curl bars", async () => {
    assert.equal(curlPercent("下载 still.fail station…\n\r                 0.0%"), 0);
    assert.equal(curlPercent("\r###   12.4%\r########   44.9%\r#########  45."), 44);
    assert.equal(curlPercent("\r######## 100.0%\n"), 100);
    for (const log of ["", "\r#=#=#", "error 44.0%", "### NaN%", "### 101.0%", "### -1.0%"]) assert.equal(curlPercent(log), null, log);
    const dir = temp();
    const log = join(dir, "update.log");
    assert.equal(await stationDownloadPercent(log), null);
    writeFileSync(log, `${"old output\n".repeat(1000)}\r### 37.2%`);
    assert.equal(await stationDownloadPercent(log), 37);
  });

  test("the station's download percent changes are told and cleared", async (t) => {
    const dir = temp();
    const runDir = join(dir, "run");
    mkdirSync(runDir, { recursive: true });
    const updates = installed(dir, "1300", null);
    t.after(() => updates.close());
    let told = 0;
    updates.changes(() => told++);
    writeFileSync(join(runDir, "update.step"), "download\n");
    writeFileSync(join(runDir, "update.log"), "\r### 12.4%");
    await updates.follow({ at: Date.now(), from: "0.1.1300" });
    assert.equal(station(updates).percent, 12);
    writeFileSync(join(runDir, "update.log"), "\r### 12.4%\r######## 44.9%");
    await until("44%", () => station(updates).percent === 44, t.signal);
    assert.ok(told >= 2);
    writeFileSync(join(runDir, "update.step"), "handoff\n");
    await until("handoff", () => station(updates).percent === undefined, t.signal);
    assert.equal(station(updates).progress, "正在交接给新版本（agent 不中断）");
    writeFileSync(join(runDir, "update.exit"), "0\n");
    await until("ended", () => station(updates).state === "idle", t.signal);
    assert.equal(station(updates).percent, undefined);
    // The same version as it started from: it says so.
    assert.equal(station(updates).done, "已是最新版本");
  });

  test("a failed installer says what it said last", async (t) => {
    const dir = temp();
    const runDir = join(dir, "run");
    mkdirSync(runDir, { recursive: true });
    const updates = installed(dir, "1300", null);
    t.after(() => updates.close());
    // And says it on the station's log, which still.fail hears of (a station of someone else's workspace: its pages
    // are not ours to look at).
    const lines: Line[] = [];
    hearLines((l) => void (l.at === "updates" && lines.push(l)));
    t.after(() => hearLines(null));
    writeFileSync(join(runDir, "update.log"), "one\ntwo\nthree\nfour\nfive\n");
    await updates.follow({ at: Date.now(), from: "0.1.1300" });
    writeFileSync(join(runDir, "update.exit"), "1\n");
    await until("failed", () => station(updates).state === "failed", t.signal);
    assert.equal(station(updates).message, "two\nthree\nfour\nfive");
    // (the log is the process's, heard by one listener: this suite's other tests, run beside this one, say their updates
    // ended there too, one of them well)
    const ended = lines.filter((l) => l.message === "the station's update ended").map((l) => l.fields);
    assert.ok(ended.some((f) => isDeepStrictEqual(f, { failed: true, why: "two\nthree\nfour\nfive" })), JSON.stringify(ended));
  });

  test("switched back from the beta the stable release is offered and kept in the config", async (t) => {
    const dir = temp();
    const updates = installed(dir, "1300", "beta");
    t.after(() => updates.close());
    assert.equal(updates.channel(), "beta");
    let line = updates.stationWith("0.1.1310");
    assert.deepEqual([line.channel, line.newer, line.downgrade], ["beta", true, false]);

    await updates.setChannel("stable");
    assert.equal(updates.channel(), "stable");
    assert.equal(JSON.parse(readFileSync(join(dir, "config.json"), "utf8")).updateChannel, "stable");
    // What was read from the beta's feed is not the stable one's.
    line = station(updates);
    assert.deepEqual([line.latest, line.newer, line.downgrade], [undefined, false, false]);
    line = updates.stationWith("0.1.1200");
    assert.deepEqual([line.channel, line.newer, line.downgrade], ["stable", false, true]);

    // A station that never was on the beta is not offered an older one.
    const other = temp();
    const stable = installed(other, "1300", null);
    t.after(() => stable.close());
    line = stable.stationWith("0.1.1200");
    assert.deepEqual([line.channel, line.newer, line.downgrade], ["stable", false, false]);
    // Read again in a new process from a config that says beta: the feed it reads is the beta's.
    setChannelIn(other, "beta");
    const again = installed(other, "1300", null);
    t.after(() => again.close());
    assert.equal(again.channel(), "beta");
  });

  test("turned on, the station updates itself to each newer release once", async (t) => {
    const dir = temp();
    const updates = installed(dir, "1300", null);
    t.after(() => updates.close());
    assert.equal(updates.stationWith("0.1.1310").auto, false);
    assert.equal(updates.toUpdateTo(), null, "not unless turned on");
    new ConfigFile(dir).update((raw) => (raw.autoUpdate = true));
    assert.equal(updates.stationWith("0.1.1310").auto, true);
    assert.equal(updates.toUpdateTo(), "0.1.1310");
    // Already the latest, or the latest is older: nothing.
    updates.stationWith("0.1.1300");
    assert.equal(updates.toUpdateTo(), null);
    updates.stationWith("0.1.1290");
    assert.equal(updates.toUpdateTo(), null);
    // A version it went for (and failed to get) is not tried again; the next one is.
    updates.tried = "0.1.1310";
    updates.stationWith("0.1.1310");
    assert.equal(updates.toUpdateTo(), null);
    updates.stationWith("0.1.1320");
    assert.equal(updates.toUpdateTo(), "0.1.1320");
    // While a runtime installs: not yet, nor by hand (a handover or restart would leave it unfollowed).
    updates.poke("codex", (i) => (i.updating = Date.now()));
    assert.equal(updates.toUpdateTo(), null);
    await assert.rejects(updates.update("station", "zh"), (e: Error) => e.message.includes("Codex 正在安装"));
    updates.poke("codex", (i) => (i.updating = null));
    assert.equal(updates.toUpdateTo(), "0.1.1320");
    // While an update goes on: nothing more, nor a runtime installed meanwhile.
    updates.poke("station", (i) => (i.updating = Date.now()));
    assert.equal(updates.toUpdateTo(), null);
    await assert.rejects(updates.update("codex", "zh"), (e: Error) => e.message.includes("station 正在更新"));

    // Switched back from the beta, the older stable release is offered, but not gone to by itself.
    const other = temp();
    const beta = installed(other, "1300", "beta");
    t.after(() => beta.close());
    new ConfigFile(other).update((raw) => {
      raw.autoUpdate = true;
      raw.updateChannel = "stable";
    });
    assert.ok(beta.stationWith("0.1.1200").downgrade);
    assert.equal(beta.toUpdateTo(), null);
  });

  test("automatic updates do not wait for running turns or people using the station", async (t) => {
    const dir = temp();
    const updates = installed(dir, "1300", null);
    t.after(() => updates.close());
    new ConfigFile(dir).update((raw) => (raw.autoUpdate = true));
    updates.stationWith("0.1.1310");
    // A turn running (a Slack one too): it is handed over, not waited for.
    updates.countRunning(() => 1);
    assert.equal(updates.toUpdateTo(), "0.1.1310");
  });

  test("an automatic update waits for a command run with a vault grant, whose proxy would go with this process", async (t) => {
    const dir = temp();
    const updates = installed(dir, "1300", null);
    t.after(() => updates.close());
    new ConfigFile(dir).update((raw) => (raw.autoUpdate = true));
    updates.stationWith("0.1.1310");
    const first = hold(), second = hold();
    assert.equal(updates.toUpdateTo(), null);
    first();
    first();
    assert.equal(updates.toUpdateTo(), null, "one still runs (letting go twice is once)");
    second();
    assert.equal(updates.toUpdateTo(), "0.1.1310");
  });

  // The installer here is install.sh, run by sh; Windows' (install.ps1, by a scheduled task) is the next test's.
  const shInstaller = { skip: WINDOWS && "install.sh is macOS's and Linux's" };

  test("on Windows the update's script runs the release's install.ps1, its words in UTF-8 and its exit kept", { skip: !WINDOWS && "Windows'" }, async () => {
    const dir = temp();
    const run = join(dir, "run 'x'");
    mkdirSync(run);
    // The release's installer, as startInstaller copies it there.
    writeFileSync(join(run, "install.ps1"), String.fromCharCode(0xfeff) + [
      "Write-Host ('下载 still.fail station… ' + $env:STILLFAIL_CHANNEL + ' ' + $env:STILLFAIL_DATA + ' ' + $env:STILLFAIL_RELEASE_SHA256)",
      "[Console]::Error.WriteLine('没能更新')",
      "exit 3",
    ].join("\r\n"));
    const env = { STILLFAIL_DATA: dir, STILLFAIL_CHANNEL: "beta", STILLFAIL_RELEASE_SHA256: SHA_A, PATH: "C:\\nowhere" };
    const ps1 = join(run, "update.ps1");
    const text = windowsUpdateScript(run, env, "still.fail station (test, not registered) update");
    // Only the station's own variables: the task has the user's PATH.
    assert.ok(!text.includes("nowhere"));
    writeFileSync(ps1, text);
    // Run here as the task runs it (no task: its removal at the end finds none).
    await new Promise<void>((resolve, reject) =>
      execFile("powershell.exe", ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", ps1], { timeout: 60_000 }, (e, _out, err) => (e ? reject(new Error(`${e.message} ${err}`)) : resolve())),
    );
    assert.equal(readFileSync(join(run, "update.exit"), "utf8").trim(), "3");
    const log = readFileSync(join(run, "update.log"), "utf8");
    assert.ok(log.includes(`下载 still.fail station… beta ${dir} ${SHA_A}`), log);
    assert.ok(log.includes("没能更新"), log);
  });

  test("the station is updated by the installer its release carries, told what the signed release hashes to, followed to its end", shInstaller, async (t) => {
    const dir = temp();
    const [origin, server, asked, finish, installer] = await cloudWithRelease("0.1.1310", "1310", true);
    t.after(() => server.close());
    const updates = installed(dir, "1300", null, { origin: () => origin, env: { PATH: "/usr/bin:/bin" } }, installer);
    t.after(() => updates.close());
    await updates.check();
    assert.deepEqual([station(updates).latest, station(updates).newer, station(updates).updatable], ["0.1.1310", true, true]);
    await updates.update("station", "zh");
    assert.equal(station(updates).state, "updating");
    assert.ok(existsSync(join(dir, "run", "update.started")));
    // Asked again meanwhile: refused.
    await assert.rejects(updates.update("station", "zh"), (e: Error) => e.message === "Station 正在更新");
    finish();
    await until("ended", () => station(updates).state === "idle", t.signal);
    assert.equal(station(updates).done, "已更新到 0.1.1310，agent 未中断");
    // Never the cloud's installer.
    assert.ok(!asked.some((a) => a.startsWith("/install")), asked.join());
    assert.equal(readFileSync(join(dir, "installer-saw"), "utf8").trim(), `stable ${dir}\n${origin} ${SHA_A} ${SHA_B} zh`);
    assert.ok(!existsSync(join(dir, "run", "update.started")));
    assert.equal(readFileSync(join(dir, "run", "update.exit"), "utf8").trim(), "0");
  });

  test("an installer this process could not start is started by the launcher, told what it would have been, and followed", async (t) => {
    const dir = temp();
    const [origin, server] = await cloudWithRelease("0.1.1310", "1310");
    t.after(() => server.close());
    const asked: [string, Record<string, string>][] = [];
    const updates = installed(dir, "1300", null, {
      origin: () => origin, env: { PATH: "/usr/bin:/bin" }, startInstaller: async () => false,
      launcherInstaller: (script, env) => void asked.push([script, env]),
    }, "#!/bin/sh\n");
    t.after(() => updates.close());
    await updates.check();
    await updates.update("station", "zh");
    assert.equal(asked.length, 1);
    assert.equal(asked[0]![0], join(dir, "app", "bin", "install.zh.sh"));
    assert.equal(asked[0]![1].STILLFAIL_DATA, dir);
    assert.equal(asked[0]![1].STILLFAIL_RELEASE_SHA256, SHA_A);
    assert.equal(station(updates).state, "updating", "followed as one started here");
    assert.ok(existsSync(join(dir, "run", "update.started")));
  });

  test("an installer neither this process nor a launcher from before could start is a failure said", async (t) => {
    const dir = temp();
    const [origin, server] = await cloudWithRelease("0.1.1310", "1310");
    t.after(() => server.close());
    const updates = installed(dir, "1300", null, { origin: () => origin, env: { PATH: "/usr/bin:/bin" }, startInstaller: async () => false }, "#!/bin/sh\n");
    t.after(() => updates.close());
    await updates.check();
    await assert.rejects(updates.update("station", "zh"));
    assert.notEqual(station(updates).state, "updating");
  });

  test("a feed that does not verify offers nothing, and nothing is installed from it", shInstaller, async (t) => {
    const unsigned = { version: "0.1.1310", build: 1310, commit: "0".repeat(40) };
    const forged = feedOf(1310, {}, OTHER);
    // Words changed after signing: the archive's hash swapped for another.
    const good = feedOf(1310);
    const words = JSON.parse(Buffer.from(good.release, "base64").toString("utf8"));
    for (const b of Object.values<any>(words.builds)) b.sha256 = "c".repeat(64);
    const tampered = { ...good, release: Buffer.from(JSON.stringify(words)).toString("base64") };
    // The signed words of 1310 under a feed that says 1320.
    const relabeled = { ...feedOf(1310), version: "0.1.1320" };
    for (const [name, feed] of Object.entries({ unsigned, forged, tampered, relabeled })) {
      const dir = temp();
      const [origin, server, asked, , installer] = await cloudWithRelease("0.1.1310", "1310", false, feed);
      t.after(() => server.close());
      const updates = installed(dir, "1300", null, { origin: () => origin, env: { PATH: "/usr/bin:/bin" } }, installer);
      t.after(() => updates.close());
      new ConfigFile(dir).update((raw) => (raw.autoUpdate = true));
      await updates.check();
      assert.deepEqual([station(updates).latest, station(updates).newer, updates.toUpdateTo()], [undefined, false, null], name);
      // Asked anyway (a page from before it read): refused, and not left updating.
      await assert.rejects(updates.update("station", "zh"), (e: Error) => e.message.startsWith("此版本签名校验失败"), name);
      assert.equal(station(updates).state, "idle", name);
      assert.ok(!existsSync(join(dir, "installer-ran")), name);
      assert.ok(!asked.some((a) => a.startsWith("/install")), name);
    }
  });

  test("an older signed release is not installed, but back to the stable one from the beta", shInstaller, async (t) => {
    const [origin, server, , , installer] = await cloudWithRelease("0.1.1290", "1290");
    t.after(() => server.close());
    const dir = temp();
    const updates = installed(dir, "1300", null, { origin: () => origin, env: { PATH: "/usr/bin:/bin" } }, installer);
    t.after(() => updates.close());
    await updates.check();
    assert.deepEqual([station(updates).latest, station(updates).newer, station(updates).downgrade], ["0.1.1290", false, false]);
    await assert.rejects(updates.update("station", "zh"), (e: Error) => e.message === "0.1.1290 早于当前的 0.1.1300，不予更新");
    assert.ok(!existsSync(join(dir, "installer-ran")));
    // Installed from the beta and put on the stable channel by a person: going back is theirs to ask.
    const beta = temp();
    const back = installed(beta, "1300", "beta", { origin: () => origin, env: { PATH: "/usr/bin:/bin" } }, installer);
    t.after(() => back.close());
    await back.setChannel("stable");
    assert.deepEqual([station(back).latest, station(back).downgrade], ["0.1.1290", true]);
    await back.update("station", "zh");
    await until("ended", () => station(back).state === "idle", t.signal);
    assert.equal(readFileSync(join(beta, "installer-ran"), "utf8"), "ran\n");
  });

  test("turned on, the station updates itself by the installer as soon as it reads a newer release, once", shInstaller, async (t) => {
    const dir = temp();
    // (its download held until it is seen updating: a quick installer could end before the first look at it)
    const [origin, server, asked, finish, installer] = await cloudWithRelease("0.1.1310", "1310", true);
    t.after(() => server.close());
    const time = testClock();
    const updates = installed(dir, "1300", null, { origin: () => origin, env: { PATH: "/usr/bin:/bin" }, timing: { followLook: 200 }, clock: time.clock }, installer);
    t.after(() => updates.close());
    new ConfigFile(dir).update((raw) => (raw.autoUpdate = true));
    /// Moves its time on by `ms` until `f` holds (what it waits for meanwhile may be a real process).
    const steps = async (ms: number, f: () => boolean) => {
      while (!f()) {
        t.signal.throwIfAborted();
        await time.adjust(ms);
        await sleep(10, undefined, { signal: t.signal });
      }
    };
    // A reading of what is out after the update ended once the feed was asked a third time (the first reading, the
    // update's own, then that one; it decides as it ends).
    const feeds = () => asked.filter((a) => a.startsWith("/releases/station.json")).length;
    updates.start();
    // It reads what is out at once, and updates itself by the installer.
    await until("read", () => station(updates).latest === "0.1.1310", t.signal);
    await steps(50, () => station(updates).state === "updating");
    finish();
    await until("the installer ended", () => existsSync(join(dir, "run", "update.exit")), t.signal);
    await steps(200, () => station(updates).done === "已更新到 0.1.1310，agent 未中断");
    // Then reads what is out again: the feed still says 0.1.1310 and the release is 0.1.1310, so nothing more (its
    // decision taken as the reading ends), nor on its rounds after.
    await until("read again", () => station(updates).version === "0.1.1310", t.signal);
    assert.equal(station(updates).latest, "0.1.1310", "the post-update feed was read successfully");
    assert.ok(feeds() >= 3, "the post-update check asked for the feed");
    for (let i = 0; i < 5; i++) {
      await time.adjust(50);
      await settle();
    }
    assert.equal(station(updates).state, "idle");
    assert.equal(readFileSync(join(dir, "installer-ran"), "utf8"), "ran\n");
  });

  // An update after an update: the one before left its copy of the installer in run/, which the next must replace. The
  // MoonBit station's copy made a new file only, so every station that had updated once never started an installer
  // again ("the station's installer not started", 0.1.9984 to 0.1.9996) and no later release could reach it.
  test("the station updates itself again after an update, the installer the update before left in run/ replaced", shInstaller, async (t) => {
    const dir = temp();
    let latest = 1310;
    const asked: string[] = [];
    const [origin, server] = await serve((path) => {
      asked.push(path);
      if (path === "/releases/station.json") return { body: JSON.stringify(feedOf(latest)) };
      if (path === "/download") return { type: "text/plain", body: "" };
      return null;
    });
    t.after(() => server.close());
    // (the release's installer: it puts the build the feed says, as installing that release would)
    const installer = `#!/bin/sh
set -eu
curl -fsS "${origin}/download" > /dev/null
echo "$STILLFAIL_RELEASE_SHA256" >> "$STILLFAIL_DATA/installer-ran"
cat "$STILLFAIL_DATA/next-build" > "$STILLFAIL_DATA/app/BUILD"
`;
    const time = testClock();
    const updates = installed(dir, "1300", null, { origin: () => origin, env: { PATH: "/usr/bin:/bin" }, timing: { followLook: 200 }, clock: time.clock }, installer);
    t.after(() => updates.close());
    new ConfigFile(dir).update((raw) => (raw.autoUpdate = true));
    const steps = async (ms: number, f: () => boolean) => {
      while (!f()) {
        t.signal.throwIfAborted();
        await time.adjust(ms);
        await sleep(10, undefined, { signal: t.signal });
      }
    };
    const ran = () => (existsSync(join(dir, "installer-ran")) ? readFileSync(join(dir, "installer-ran"), "utf8").trim().split("\n").length : 0);
    writeFileSync(join(dir, "next-build"), "1310\n");
    updates.start();
    await steps(200, () => ran() === 1 && station(updates).version === "0.1.1310");
    assert.ok(existsSync(join(dir, "run", "install.sh")), "the update left its copy of the installer in run/");
    // The next release: the same station, the copy still there, updates again.
    latest = 1320;
    writeFileSync(join(dir, "next-build"), "1320\n");
    // (still.fail cloud tells it a release is out: it reads what is out, as agents.ts has it on the plane's `release`)
    await updates.check();
    await steps(200, () => ran() === 2 && station(updates).version === "0.1.1320");
    assert.equal(readFileSync(join(dir, "app", "BUILD"), "utf8"), "1320\n");
  });

  test("an installer that puts the next release in place before its start is answered says it updated from the release before", async (t) => {
    const dir = temp();
    const [origin, server] = await cloudWithRelease("0.1.1310", "1310");
    t.after(() => server.close());
    // Started and ended at once: the next BUILD in place, its handover step and exit written as it starts.
    const startInstaller = async (_script: string, runDir: string) => {
      writeFileSync(join(dir, "app", "BUILD"), "1310\n");
      writeFileSync(join(runDir, "update.step"), "handoff\n");
      writeFileSync(join(runDir, "update.exit"), "0\n");
      return true;
    };
    const updates = installed(dir, "1300", null, { origin: () => origin, startInstaller }, "#!/bin/sh\n");
    t.after(() => updates.close());
    await updates.check();
    await updates.update("station", "zh");
    await until("ended", () => station(updates).state === "idle", t.signal);
    assert.equal(station(updates).done, "已更新到 0.1.1310，agent 未中断");
    assert.ok(!existsSync(join(dir, "run", "update.started")), "what it followed is let go of");
  });

  // The station's own line was 未安装 until every runtime's version had been read: on a Windows station whose runtime's
  // `--version` never ended, for good, and the page said 正在检查版本 meanwhile (2026-11-18).
  test("the station is there with its version as it is made, before anything is read", async (t) => {
    const updates = installed(temp(), "1300", null);
    t.after(() => updates.close());
    const line = station(updates);
    assert.deepEqual([line.installed, line.version, line.note, line.updatable, line.channel], [true, "0.1.1300", undefined, true, "stable"]);
    assert.equal(line.latest, undefined);
    assert.equal(line.newer, false);
    const elsewhere = temp();
    mkdirSync(join(elsewhere, "x"));
    writeFileSync(join(elsewhere, "x", "BUILD"), "1300");
    const other = new Updates({ app: join(elsewhere, "x"), data: elsewhere, config: new ConfigFile(elsewhere), origin: () => null, env: { PATH: "/nowhere" }, stationOnly: true });
    t.after(() => other.close());
    assert.deepEqual([station(other).installed, station(other).version, station(other).note], [true, "0.1.1300", "并非通过安装脚本安装，无法在此更新"]);
  });

  // A runtime whose version is slow to come (here Codex's check of its host, which never answers) held back the station's
  // release with it: read, but not shown, nor updated to, until every runtime had been read.
  test("the station's latest is shown and updated to as soon as it is read, while a runtime is still being read", shInstaller, async (t) => {
    const dir = temp();
    const [origin, server, , finish, installer] = await cloudWithRelease("0.1.1310", "1310", true);
    t.after(() => server.close());
    const bin = join(dir, "bin");
    script(join(bin, "codex"), "#!/bin/sh\necho codex-cli 0.46.0\n");
    let probed = 0;
    // Codex's check of its host answers only once the test lets it.
    let answer = () => {};
    const answered = new Promise<null>((r) => (answer = () => r(null)));
    const updates = installed(dir, "1300", null, { origin: () => origin, env: { PATH: withSystem(bin) }, codexHostProbe: () => ((probed += 1), answered) }, installer);
    new ConfigFile(dir).update((raw) => (raw.autoUpdate = true));
    let read = false;
    const reading = updates.check().then(() => (read = true));
    await until("the station's latest read", () => station(updates).latest === "0.1.1310", t.signal);
    assert.equal(station(updates).newer, true);
    // Updating itself to it, though Codex's reading has not ended.
    await until("updating", () => station(updates).state === "updating", t.signal);
    assert.equal(probed, 1);
    assert.equal(read, false, "the runtimes' reading goes on");
    finish();
    await until("the installer ended", () => existsSync(join(dir, "run", "update.exit")), t.signal);
    answer();
    await reading;
    await updates.close();
  });

  test("a runtime whose reading fails keeps what it was, and the others and the station are read", { skip: WINDOWS && "a shell script as codex" }, async (t) => {
    const dir = temp();
    const bin = join(dir, "bin");
    script(join(bin, "codex"), "#!/bin/sh\necho codex-cli 0.46.0\n");
    let probed = 0;
    const updates = installed(dir, "1300", null, { env: { PATH: withSystem(bin) }, codexHostProbe: () => ((probed += 1), Promise.reject(new Error("the probe broke"))) });
    t.after(() => updates.close());
    // (it threw out of the whole reading before: nothing read was taken)
    await updates.check();
    assert.equal(probed, 1);
    const codex = updates.get("en").find((l) => l.id === "codex")!;
    assert.equal(codex.installed, false, "as it was before (never read)");
    assert.ok(station(updates).checkedAt !== undefined);
    assert.equal(station(updates).installed, true);
  });

  // A first reading that failed was tried again only `every` (6 h) later, and then of the runtimes alone: the station's
  // release was never read, the page waiting on it for good.
  test("a first reading that failed is tried again within a minute, the station's release with it", async (t) => {
    const dir = temp();
    const [origin, server] = await cloudWithRelease("0.1.1310", "1310");
    t.after(() => server.close());
    const time = testClock();
    const updates = installed(dir, "1300", null, { origin: () => origin, stationOnly: true, clock: time.clock });
    t.after(() => updates.close());
    const own = updates as unknown as { readStation: (channel: string) => Promise<unknown> };
    const readStation = own.readStation.bind(updates);
    let tries = 0;
    own.readStation = (channel) => ((tries += 1), tries === 1 ? Promise.reject(new Error("the network is away")) : readStation(channel));
    updates.start();
    // (its first look is due at once on its clock)
    while (tries === 0) {
      t.signal.throwIfAborted();
      await time.adjust(0);
      await sleep(10, undefined, { signal: t.signal });
    }
    // Its clock on a second at a time: the reading again starts within the minute (its feed then read for real).
    let waited = 0;
    while (tries === 1) {
      t.signal.throwIfAborted();
      assert.ok(waited < 60_000, `not read again within ${waited} ms`);
      await time.adjust(1_000);
      waited += 1_000;
      await sleep(10, undefined, { signal: t.signal });
    }
    await until("the station's release read", () => station(updates).latest === "0.1.1310", t.signal);
    assert.equal(tries, 2);
    assert.equal(station(updates).newer, true);
  });

  test("a station not installed by the installer, or not in a workspace, is not updated here", async (t) => {
    const dir = temp();
    const app = join(dir, "elsewhere");
    mkdirSync(app);
    writeFileSync(join(app, "BUILD"), "1300");
    const updates = new Updates({ app, data: dir, config: new ConfigFile(dir), origin: () => "http://127.0.0.1:1", registry: "http://127.0.0.1:1", devinManifest: "http://127.0.0.1:1", env: { PATH: "/nowhere" } });
    t.after(() => updates.close());
    await updates.check();
    let line = station(updates);
    assert.deepEqual([line.note, line.updatable, line.channel, line.auto], ["并非通过安装脚本安装，无法在此更新", false, undefined, undefined]);
    await assert.rejects(updates.update("station", "en"), /Station: /);
    await assert.rejects(updates.setAuto(true, "zh"), (e: Error) => e.message === "Station：并非通过安装脚本安装，无法在此更新");
    const unjoined = installed(temp(), "1300", null, { origin: () => null });
    t.after(() => unjoined.close());
    await unjoined.check();
    line = station(unjoined);
    assert.equal(line.note, "尚未加入 workspace，无法更新");
    await assert.rejects(unjoined.update("nope", "zh"), (e: Error) => e.message === "不存在 nope");
  });

  describe("Codex installed by npm (one build file in the temp directory: one at a time)", () => {
    test("a runtime the machine has not is installed with npm, its download measured, its version pinned", async (t) => {
      const [registry, server, bin, said] = await codexWorld("0.47.0");
      t.after(() => server.close());
      const dir = temp();
      let changed = 0;
      const updates = installed(dir, "1300", null, { registry, env: { PATH: withSystem(bin), HOME: dir }, runtimeChanged: () => changed++ });
      t.after(() => updates.close());
      await updates.check();
      let codex = updates.get("zh")[2]!;
      assert.deepEqual([codex.installed, codex.updatable, codex.latest, codex.state], [false, true, "0.47.0", "idle"]);
      const percents: number[] = [];
      updates.changes(() => {
        const p = updates.get("zh")[2]!.percent;
        if (p !== undefined) percents.push(p);
      });
      await updates.update("codex", "zh");
      assert.equal(updates.get("zh")[2]!.state, "updating");
      await until("installed", () => updates.get("zh")[2]!.state !== "updating", t.signal);
      codex = updates.get("zh")[2]!;
      assert.deepEqual([codex.installed, codex.version, codex.newer, codex.state, codex.message], [true, "0.47.0", false, "idle", undefined]);
      assert.equal(changed, 1);
      assert.equal(percents.at(-1), 100);
      const asked = readFileSync(said, "utf8").trim().split("\n");
      assert.ok(asked[0]!.startsWith("cache add "), asked.join("|"));
      assert.equal(asked[1], "install -g @openai/codex@0.47.0 --prefer-online");
    });

    test("an install that leaves nothing on the station's PATH says so", async (t) => {
      const [registry, server, bin] = await codexWorld(null);
      t.after(() => server.close());
      const dir = temp();
      const updates = installed(dir, "1300", null, { registry, env: { PATH: withSystem(bin), HOME: dir } });
      t.after(() => updates.close());
      await updates.check();
      await updates.update("codex", "zh");
      await until("failed", () => updates.get("zh")[2]!.state === "failed", t.signal);
      assert.equal(updates.get("zh")[2]!.message, `${exe(join(bin, "npm"))} 已完成，但 station 的 PATH 中仍找不到 codex：可能安装到了其他位置`);
    });
  });

  test("version refusals share the software page's update of the existing Codex installation", { skip: WINDOWS && "Homebrew is macOS's" }, async (t) => {
    const [registry, server] = await serve((path) => path === "/@openai/codex/latest" ? { body: JSON.stringify({ version: "0.47.0" }) } : null);
    t.after(() => server.close());
    const dir = temp(), bin = join(dir, "bin"), codex = join(dir, "Cellar/codex/0.46.0/bin/codex"), calls = join(dir, "brew-calls");
    mkdirSync(bin);
    script(codex, "#!/bin/sh\necho 'codex-cli 0.46.0'\n");
    symlinkSync(codex, join(bin, "codex"));
    script(join(bin, "brew"), `#!/bin/sh\necho "$*" >> "${calls}"\nprintf '#!/bin/sh\\necho "codex-cli 0.47.0"\\n' > "${codex}.sh"\n`);
    const updates = installed(dir, "1300", null, { registry, env: { PATH: withSystem(bin), HOME: dir }, codexHostProbe: async () => null });
    t.after(() => updates.close());
    await Promise.all([updates.updateOldCodex("0.46.0", "zh"), updates.updateOldCodex("0.46.0", "zh")]);
    assert.deepEqual(readFileSync(calls, "utf8").trim().split("\n"), ["upgrade codex"]);
    assert.equal(updates.get("zh").find((item) => item.id === "codex")!.version, "0.47.0");
    // A stale app-server whose binary is already newer does not run a second install.
    await updates.updateOldCodex("0.46.0", "zh");
    assert.equal(readFileSync(calls, "utf8").trim(), "upgrade codex");
    await assert.rejects(updates.updateOldCodex("0.47.0", "zh"), /没有可用的更新版本/);
  });

  for (const complete of [true, false]) {
    test(`repairing an incomplete Codex ${complete ? "switches to npm and keeps the old entry" : "keeps the old entry when npm is incomplete"}`, { skip: !machine.codexStandalone }, async (t) => {
      const target = npmPlatform();
      const triples: Record<string, string> = { "linux-x64": "x86_64-unknown-linux-musl", "linux-arm64": "aarch64-unknown-linux-musl", "darwin-x64": "x86_64-apple-darwin", "darwin-arm64": "aarch64-apple-darwin" };
      if (!target || !triples[target]) return t.skip("no supported Codex npm package");
      const dir = temp(), bin = join(dir, "bin"), original = join(dir, "original", "codex"), entry = join(bin, "codex");
      script(original, "#!/bin/sh\necho 'codex-cli 0.166.0'\n");
      mkdirSync(bin);
      symlinkSync(original, entry);
      const old = realpathSync(entry);
      script(join(bin, "npm"), `#!/bin/sh
if [ "$1" != install ]; then exit 0; fi
while [ "$#" -gt 0 ]; do
  if [ "$1" = --prefix ]; then shift; prefix="$1"; fi
  shift
done
root="$prefix/lib/node_modules/@openai/codex"
pkg="$root/node_modules/@openai/codex-${target}"
mkdir -p "$prefix/bin" "$root/bin" "$pkg/vendor/${triples[target]}/bin"
printf '#!/bin/sh\\necho codex-cli 0.166.0\\n' > "$root/bin/codex.js"
chmod +x "$root/bin/codex.js"
printf '{}' > "$pkg/package.json"
printf '\\177ELF1234' > "$pkg/vendor/${triples[target]}/bin/codex"
chmod +x "$pkg/vendor/${triples[target]}/bin/codex"
${complete ? `printf '#!/bin/sh\\nexit 0\\n' > "$pkg/vendor/${triples[target]}/bin/codex-code-mode-host"; chmod +x "$pkg/vendor/${triples[target]}/bin/codex-code-mode-host"` : ":"}
ln -s ../lib/node_modules/@openai/codex/bin/codex.js "$prefix/bin/codex"
echo 'added 2 packages'
`);
      const changed: unknown[][] = [];
      const updates = installed(dir, "1300", null, {
        env: { PATH: withSystem(bin), HOME: dir },
        codexHostProbe: async (found) => found.real === old ? { binary: old, helper: join(dirname(old), "codex-code-mode-host") } : null,
        runtimeChanged: (...args) => changed.push(args),
      });
      t.after(() => updates.close());
      await updates.check();
      assert.equal(updates.get("zh")[2]!.repairable, true);
      await updates.repairCodex();
      await until("repair ended", () => updates.get("zh")[2]!.state !== "updating", t.signal);
      const codex = updates.get("zh")[2]!;
      if (complete) {
        assert.equal(codex.state, "idle");
        assert.equal(codex.version, "0.166.0");
        assert.match(realpathSync(entry), /node_modules\/@openai\/codex\/bin\/codex\.js$/);
        const backup = readdirSync(bin).find((name) => name.startsWith("codex.stillfail-backup-"));
        assert.ok(backup);
        assert.equal(readlinkSync(join(bin, backup)), original);
        assert.match(codex.done ?? "", /已用 npm 修复/);
        assert.deepEqual(changed, [["codex", true, true]]);
      } else {
        assert.equal(codex.state, "failed");
        assert.match(codex.message ?? "", /安装不完整/);
        assert.equal(readlinkSync(entry), original);
        assert.equal(readdirSync(bin).some((name) => name.startsWith("codex.stillfail-backup-")), false);
        assert.deepEqual(changed, [["codex", true, false]]);
      }
    });
  }

  test("a runtime npm installs in its own Node's bin, off PATH, is linked beside the npm on PATH", { skip: WINDOWS && "npm's .cmd stays in its prefix (on PATH)" }, async (t) => {
    const [registry, server] = await serve((path) => (path === "/@xai-official/grok/latest" ? { body: JSON.stringify({ version: "1.0.62" }) } : null));
    t.after(() => server.close());
    // A Node unpacked in its own directory, only its npm linked into a directory on PATH (as ~/.local/bin).
    const dir = temp();
    const [node, bin] = [join(dir, "node-v24"), join(dir, "bin")];
    script(join(node, "bin", "npm"), `#!/bin/sh
case "$1" in
  prefix) echo "${node}" ;;
  install) printf '#!/bin/sh\necho "grok 1.0.62 (1474f9cb)"\n' > "${node}/bin/grok.sh"; /bin/ln "${launcher()}" "${node}/bin/grok"; echo "added 1 package" ;;
esac
`);
    mkdirSync(bin);
    symlinkSync(join(node, "bin", "npm"), join(bin, "npm"));
    const updates = installed(dir, "1300", null, { registry, env: { PATH: withSystem(bin), HOME: dir } });
    t.after(() => updates.close());
    await updates.check();
    const grok = () => updates.get("zh").find((v) => v.id === "grok")!;
    assert.deepEqual([grok().installed, grok().updatable], [false, true]);
    await updates.update("grok", "zh");
    await until("installed", () => grok().state !== "updating", t.signal);
    assert.deepEqual([grok().installed, grok().version, grok().state, grok().message], [true, "1.0.62", "idle", undefined]);
    assert.equal(readlinkSync(join(bin, "grok")), join(node, "bin", "grok"));
  });

  /// nodejs.org as the station reads it: Node `version`'s build for this machine (an npm that installs Grok Build in the
  /// prefix it is given, as npm puts a command there: bin/ and lib/node_modules, on Windows a .cmd at its top), and its
  /// SHASUMS256 (`sum`: the build's, unless given); and the registry's latest Grok Build.
  async function nodeWorld(version: string, sum?: string): Promise<[string, Server]> {
    const dir = temp();
    const build = machine.nodeBuild(version)!;
    const bin = join(dir, build.dist, build.bin);
    mkdirSync(bin, { recursive: true });
    script(join(bin, "npx"), "#!/bin/sh\nexit 0\n");
    script(join(bin, "npm"), `#!/bin/sh
prefix=
while [ $# -gt 0 ]; do [ "$1" = --prefix ] && prefix="$2"; shift; done
${WINDOWS
  ? `printf '@echo grok 1.0.62 (1474f9cb)\\r\\n' > "$prefix/grok.cmd"`
  : `pkg="$prefix/lib/node_modules/@xai-official/grok"
mkdir -p "$pkg/bin" "$prefix/bin"
printf '#!/bin/sh\\necho "grok 1.0.62 (1474f9cb)"\\n' > "$pkg/bin/grok"
chmod +x "$pkg/bin/grok"
ln -s ../lib/node_modules/@xai-official/grok/bin/grok "$prefix/bin/grok"`}
echo "added 1 package"
`);
    const archive = join(dir, build.archive);
    execFileSync(build.tar, [WINDOWS ? "-a" : "-z", "-cf", archive, "-C", dir, build.dist]);
    const bytes = readFileSync(archive);
    const sums = `${"0".repeat(64)}  node-v${version}-aix-ppc64.tar.gz\n${sum ?? createHash("sha256").update(bytes).digest("hex")}  ${build.archive}\n`;
    const [base, server] = await serve((path) =>
      path === "/@xai-official/grok/latest" ? { body: JSON.stringify({ version: "1.0.62" }) }
      : path === `/dist/v${version}/SHASUMS256.txt` ? { type: "text/plain", body: sums }
      : path === `/dist/v${version}/${build.archive}` ? { type: "application/octet-stream", body: bytes }
      : null);
    return [base, server];
  }

  test("where the machine has no npm, a runtime npm installs is installed with nodejs.org's Node, kept in the station's data and on its PATH only", async (t) => {
    const [base, server] = await nodeWorld("24.22.1");
    t.after(() => server.close());
    const dir = temp();
    const [data, home] = [join(dir, "data"), join(dir, "home")];
    const bin = join(home, ".local", "bin");
    mkdirSync(bin, { recursive: true });
    const env: Env = { PATH: withSystem(bin), HOME: home };
    assert.equal(await findCommandSoon("npm", env), null, "no npm on the system's PATH");
    const own = ownNode(data, "24.22.1")!;
    // Links an earlier release made into ~/.local/bin to that Node are taken away; others are left.
    if (!WINDOWS) {
      for (const name of ["node", "npm", "grok"]) symlinkSync(join(own.bin, name), join(bin, name));
      symlinkSync(join(dir, "elsewhere", "claude"), join(bin, "claude"));
    }
    const updates = installed(data, "1300", null, { registry: base, nodeDist: `${base}/dist`, env });
    writeFileSync(join(data, "app", "NODE_VERSION"), "24.22.1\n");
    t.after(() => updates.close());
    if (!WINDOWS) assert.deepEqual(readdirSync(bin), ["claude"]);
    await updates.check();
    const grok = () => updates.get("zh").find((v) => v.id === "grok")!;
    assert.deepEqual([grok().installed, grok().updatable, grok().note], [false, true, undefined]);
    await updates.update("grok", "zh");
    await until("installed", () => grok().state !== "updating", t.signal);
    assert.deepEqual([grok().installed, grok().version, grok().state, grok().message], [true, "1.0.62", "idle", undefined]);
    // Nothing of the download left beside it, nothing put in ~/.local/bin; the station's PATH has it, last.
    assert.deepEqual(readdirSync(join(data, "node")), [own.build.dist]);
    if (!WINDOWS) assert.deepEqual(readdirSync(bin), ["claude"]);
    assert.ok(machine.pathOf(env).endsWith(own.bin), machine.pathOf(env));
    assert.equal((await findCommandSoon("npm", env))!.onPath.toLowerCase(), join(own.bin, own.build.npm).toLowerCase());
    // A station started again finds it there; Grok Build updated with that Node's npm.
    const again: Env = { PATH: withSystem(bin), HOME: home };
    const later = installed(data, "1300", null, { registry: base, nodeDist: `${base}/dist`, env: again });
    t.after(() => later.close());
    assert.equal(machine.pathOf(again), machine.pathOf(env));
    if (!WINDOWS) {
      assert.deepEqual(await howToUpdateSoon("grok", (await findCommandSoon("grok", env))!, env), { program: join(own.bin, "npm"), args: ["install", "-g", "@xai-official/grok@latest", "--prefix", own.at] });
    }
  });

  test("a Node whose download does not match nodejs.org's checksum is not installed, nor anything with it", async (t) => {
    const [base, server] = await nodeWorld("24.22.1", "f".repeat(64));
    t.after(() => server.close());
    const dir = temp();
    const [data, home] = [join(dir, "data"), join(dir, "home")];
    mkdirSync(home);
    const env: Env = { PATH: withSystem(join(home, ".local", "bin")), HOME: home };
    const updates = installed(data, "1300", null, { registry: base, nodeDist: `${base}/dist`, env });
    writeFileSync(join(data, "app", "NODE_VERSION"), "24.22.1\n");
    t.after(() => updates.close());
    await updates.check();
    const grok = () => updates.get("zh").find((v) => v.id === "grok")!;
    await updates.update("grok", "zh");
    await until("failed", () => grok().state !== "updating", t.signal);
    assert.deepEqual([grok().installed, grok().state, grok().message], [false, "failed", "下载的 Node 校验失败"]);
    assert.equal(updates.get("en").find((v) => v.id === "grok")!.message, "The downloaded Node failed verification");
    assert.deepEqual(readdirSync(join(data, "node")), []);
    assert.equal(machine.pathOf(env), withSystem(join(home, ".local", "bin")));
  });

  test("Devin's latest is its installer's manifest's, and Devin as its installer put it is updated by its installer again, without the `devin setup` it ends with", { skip: WINDOWS && "a link to the version the installer keeps" }, async (t) => {
    const [manifest, server] = await serve((path) => (path === "/cli/current/manifest.json" ? { body: JSON.stringify({ version: "3000.12.0", platforms: {} }) } : null));
    t.after(() => server.close());
    // As the installer leaves it: the versions in its data directory, the command on PATH a link to the current one.
    const dir = temp();
    const [versions, bin] = [join(dir, "share", "devin", "cli", "_versions", "3000.11.92"), join(dir, "bin")];
    const now = join(dir, "now");
    script(join(versions, "devin"), `#!/bin/sh
case "$1" in
  setup) echo "Error: Login canceled" >&2; exit 1 ;;
  --version) if [ -f "${now}" ]; then echo "devin $(cat "${now}")"; else echo "devin 3000.11.92"; fi ;;
esac
`);
    mkdirSync(bin);
    symlinkSync(join(versions, "devin"), join(bin, "devin"));
    // The installer as curl fetches it: the latest put in place, then the setup it ends with (a sign-in that wants a
    // terminal).
    script(join(bin, "curl"), `#!/bin/sh
cat <<'END'
echo 3000.12.0 > "${now}"
echo "Installed devin v3000.12.0"
"${join(versions, "devin")}" setup
END
`);
    const updates = installed(dir, "1300", null, { devinManifest: `${manifest}/cli/current/manifest.json`, env: { PATH: withSystem(bin), HOME: dir } });
    t.after(() => updates.close());
    await updates.check();
    const devin = () => updates.get("zh").find((v) => v.id === "devin")!;
    assert.deepEqual([devin().installed, devin().version, devin().latest, devin().newer, devin().updatable], [true, "3000.11.92", "3000.12.0", true, true]);
    await updates.update("devin", "zh");
    await until("updated", () => devin().state !== "updating", t.signal);
    assert.deepEqual([devin().version, devin().newer, devin().state, devin().message], ["3000.12.0", false, "idle", undefined]);
  });

  test("on Windows a command beside vp.exe is Vite+'s, updated with it; one in npm's prefix with that npm", { skip: !WINDOWS && "Windows'" }, async () => {
    const dir = temp();
    writeFileSync(join(dir, "vp.exe"), "");
    writeFileSync(join(dir, "codex.cmd"), "@echo codex-cli 0.1.0\r\n");
    const env: Env = { PATH: dir };
    assert.deepEqual(await howToUpdateSoon("codex", (await findCommandSoon("codex", env))!, env), { program: join(dir, "vp.exe"), args: ["install", "-g", "@openai/codex@latest"] });
    const prefix = temp();
    mkdirSync(join(prefix, "node_modules", "@anthropic-ai", "claude-code"), { recursive: true });
    writeFileSync(join(prefix, "claude.cmd"), "@echo 2.1.0\r\n");
    writeFileSync(join(prefix, "npm.cmd"), "");
    const there: Env = { PATH: prefix };
    assert.deepEqual(await howToUpdateSoon("claude", (await findCommandSoon("claude", there))!, there), {
      program: join(prefix, "npm.cmd"), args: ["install", "-g", "@anthropic-ai/claude-code@latest", "--prefix", prefix],
    });
  });

  test("a winget package is named by the directory winget unpacked it in", () => {
    const at = (dir: string) => wingetPackage(`C:\\Users\\a\\AppData\\Local\\Microsoft\\WinGet\\Packages\\${dir}\\claude.exe`);
    assert.equal(at("Anthropic.ClaudeCode_Microsoft.Winget.Source_8wekyb3d8bbwe"), "Anthropic.ClaudeCode");
    assert.equal(at("Some_Tool_Microsoft.Winget.Source_8wekyb3d8bbwe"), "Some_Tool");
    assert.equal(wingetPackage("C:\\Program Files\\WinGet\\Packages\\OpenAI.Codex_Microsoft.Winget.Source_8wekyb3d8bbwe\\bin\\codex.exe"), "OpenAI.Codex");
    assert.equal(wingetPackage("C:\\Users\\a\\.local\\bin\\claude.exe"), null);
  });

  test("on Windows a command winget installed is updated with winget", { skip: !WINDOWS && "Windows'" }, async () => {
    const dir = join(temp(), "WinGet", "Packages", "Anthropic.ClaudeCode_Microsoft.Winget.Source_8wekyb3d8bbwe");
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "claude.exe"), "");
    const apps = temp();
    writeFileSync(join(apps, "winget.exe"), "");
    const env: Env = { PATH: [dir, apps].join(";") };
    assert.deepEqual(await howToUpdateSoon("claude", (await findCommandSoon("claude", env))!, env), {
      program: join(apps, "winget.exe"),
      noUpdate: 0x8a15002b,
      args: ["upgrade", "--id", "Anthropic.ClaudeCode", "--exact", "--silent", "--disable-interactivity", "--accept-source-agreements", "--accept-package-agreements"],
    });
  });

  test("on Windows winget with no update to apply says so, not that the update failed", { skip: !WINDOWS && "Windows'" }, async (t) => {
    const [registry, server] = await serve((path) => (path === "/@anthropic-ai/claude-code/latest" ? { body: JSON.stringify({ version: "2.2.0" }) } : null));
    t.after(() => server.close());
    const dir = temp();
    const pkg = join(dir, "WinGet", "Packages", "Anthropic.ClaudeCode_Microsoft.Winget.Source_8wekyb3d8bbwe");
    mkdirSync(pkg, { recursive: true });
    writeFileSync(join(pkg, "claude.cmd"), "@echo 2.1.0 (Claude Code)\r\n");
    const apps = join(dir, "apps");
    mkdirSync(apps);
    // winget's APPINSTALLER_CLI_ERROR_UPDATE_NOT_APPLICABLE, as cmd exits with it.
    writeFileSync(join(apps, "winget.cmd"), "@echo No available upgrade found.\r\n@exit /b -1978335189\r\n");
    const updates = installed(dir, "1300", null, { registry, env: { PATH: [pkg, apps, withSystem(dir)].join(";"), USERPROFILE: dir } });
    t.after(() => updates.close());
    await updates.check();
    const claude = () => updates.get("zh").find((v) => v.id === "claude")!;
    assert.deepEqual([claude().version, claude().latest, claude().updatable], ["2.1.0", "2.2.0", true]);
    await updates.update("claude", "zh");
    await until("failed", () => claude().state === "failed", t.signal);
    assert.equal(claude().message, "winget 暂无可在此安装的更新（其源可能还没有最新版本），未做改动：No available upgrade found.");
  });

  test("vite shims update the package with their own vp", { skip: WINDOWS && "Windows' Vite+ commands are shims of their own (the test before)" }, async () => {
    const dir = temp();
    script(join(dir, "vp"), "#!/bin/sh\nprintf '%s\\n' \"$@\"\n");
    for (const kind of ["claude", "codex"] as const) {
      symlinkSync("vp", join(dir, kindCommand(kind)));
      const env: Env = { PATH: dir };
      const f = (await findCommandSoon(kindCommand(kind), env))!;
      const how = await howToUpdateSoon(kind, f, env);
      assert.ok(!(how instanceof Unable));
      const [ok, said] = await run(how.program, how.args, env, 10_000);
      assert.ok(ok);
      assert.equal(said, `install\n-g\n${kindPackage(kind)}@latest\n`);
    }
  });

  test("a standalone update keeps the actual home and path, with shell characters", shInstaller, async () => {
    const dir = temp();
    const home = join(dir, "custom codex ' $home");
    const real = join(home, "packages/standalone/releases/0.155.1-aarch64-apple-darwin/bin/codex");
    const bin = join(dir, "visible bin ' $bin");
    script(real, "#!/bin/sh\necho 'codex-cli 0.155.1'\n");
    mkdirSync(bin, { recursive: true });
    symlinkSync(real, join(bin, "codex"));
    // A harmless installer instead of downloading or changing any real installation.
    script(join(bin, "curl"), `#!/bin/sh
cat <<'INSTALLER'
test "$CODEX_NON_INTERACTIVE" = 1 || exit 1
test "$1" = --release && test "$2" = latest || exit 2
printf '%s\\n' "$CODEX_HOME" "$CODEX_INSTALL_DIR"
INSTALLER
`);
    const env: Env = { PATH: `${bin}:/usr/bin:/bin`, CODEX_HOME: "/wrong/home" };
    const f = (await findCommandSoon("codex", env))!;
    const how = await howToUpdateSoon("codex", f, env);
    assert.ok(!(how instanceof Unable));
    const [ok, said] = await run(how.program, how.args, env, 10_000);
    assert.ok(ok, said);
    assert.equal(said, `${realpathSync(home)}\n${bin}\n`);
    assert.ok(await howToUpdateSoon("codex", { onPath: real, real }, env) instanceof Unable);
  });

  test("each runtime is updated the way it was installed", async () => {
    const dir = temp();
    for (const name of ["brew", "npm"]) script(join(dir, name), "#!/bin/sh\n");
    const env: Env = { PATH: dir };
    const [brew, npm] = [exe(join(dir, "brew")), exe(join(dir, "npm"))];
    assert.deepEqual(await howToUpdateSoon("claude", found("/Users/a/.local/share/claude/versions/2.1.284"), env), { program: "/nowhere/bin/x", args: ["update"] });
    assert.deepEqual(await howToUpdateSoon("claude", found("/opt/homebrew/Caskroom/claude-code/2.1.284/claude"), env), { program: brew, args: ["upgrade", "--cask", "claude-code"] });
    assert.deepEqual(await howToUpdateSoon("codex", found("/opt/homebrew/Cellar/codex/0.46.0/bin/codex"), env), { program: brew, args: ["upgrade", "codex"] });
    assert.deepEqual(await howToUpdateSoon("codex", found("/Users/a/.nvm/versions/node/v24/lib/node_modules/@openai/codex/bin/codex.js"), env), {
      program: npm, args: ["install", "-g", "@openai/codex@latest", "--prefix", "/Users/a/.nvm/versions/node/v24"],
    });
    assert.deepEqual(await howToUpdateSoon("claude", found("/Users/a/node/lib/node_modules/@anthropic-ai/claude-code/cli.js"), env), {
      program: npm, args: ["install", "-g", "@anthropic-ai/claude-code@latest", "--prefix", "/Users/a/node"],
    });
    // Linked from a directory beside another Node's npm: its own Node's npm, not that one.
    const node = join(dir, "node/v24.3.0");
    mkdirSync(join(node, "bin"), { recursive: true });
    writeFileSync(join(node, "bin/npm"), "");
    const linked: Found = { onPath: join(dir, "codex"), real: join(node, "lib/node_modules/@openai/codex/bin/codex.js") };
    const how = await howToUpdateSoon("codex", linked, env);
    assert.deepEqual(how, { program: join(node, "bin/npm"), args: ["install", "-g", "@openai/codex@latest", "--prefix", node] });
    assert.deepEqual(pinNpmVersion(how as any, "@openai/codex", "0.159.3").args, ["install", "-g", "@openai/codex@0.159.3", "--prefix", node, "--prefer-online"]);
    const say_ = (h: unknown) => (h as Unable).say("zh");
    assert.ok(say_(await howToUpdateSoon("codex", found("/project/node_modules/@openai/codex/bin/codex.js"), env)).includes("全局安装目录"));
    assert.ok(say_(await howToUpdateSoon("codex", found("/usr/local/bin/codex"), env)).includes("手动更新"));
    // Codex's standalone installer is a shell script: on Windows not run.
    if (WINDOWS) assert.ok(say_(await howToUpdateSoon("codex", found("C:/Users/a/.codex/packages/standalone/releases/0.1.0-x86_64-pc-windows-msvc/bin/codex.exe"), env)).includes("手动更新"));
    assert.deepEqual(await howToInstallSoon("codex", env), { program: npm, args: ["install", "-g", "@openai/codex@latest"] });
    const bare: Env = { PATH: "/nowhere", HOME: "/Users/a" };
    // Without npm: Codex by its own installer (a shell script: on Windows, a Node of the station's npm).
    const own = ownNode(join("/", "data"), "24.22.1")!;
    const build = machine.nodeBuild("24.22.1")!;
    assert.deepEqual(own, { version: "24.22.1", build, at: join("/", "data", "node", build.dist), bin: join("/", "data", "node", build.dist, build.bin) });
    const ownNpm = (pkg: string) => ({ program: join(own.bin, build.npm), args: ["install", "-g", pkg, "--prefix", own.at], node: own });
    if (WINDOWS) assert.deepEqual(await howToInstallSoon("codex", bare, own), ownNpm("@openai/codex@latest"));
    else assert.equal((await howToInstallSoon("codex", bare, own) as any).args[2], "stillfail-codex-install");
    // DeepSeek Harness and Grok Build by npm: the machine's, else a Node of the station's put in place first, into it.
    for (const kind of ["dsh", "grok"] as const) {
      const pkg = `${kindPackage(kind)}@latest`;
      assert.deepEqual(await howToInstallSoon(kind, env, own), { program: npm, args: ["install", "-g", pkg] });
      assert.deepEqual(await howToInstallSoon(kind, bare, own), ownNpm(pkg));
      assert.equal(say_(await howToInstallSoon(kind, bare)), `安装 ${kind === "dsh" ? "DeepSeek Harness" : "Grok Build"} 需要 npm：请先在本机安装 Node（含 npm）`);
    }
    assert.equal((await howToInstallSoon("claude", bare) as any).program, WINDOWS ? "powershell" : "/bin/sh");
    // Devin by its own installer: run again where it put it (`devin update` wants a terminal), by hand anywhere else;
    // installed by its installer.
    assert.deepEqual(await howToUpdateSoon("devin", found("/Users/a/.local/share/devin/cli/_versions/3000.11.92/devin"), env), machine.devinInstall);
    if (WINDOWS) assert.deepEqual(await howToUpdateSoon("devin", found("C:\\Users\\a\\AppData\\Local\\devin\\cli\\_versions\\3000.11.92\\devin.exe"), env), machine.devinInstall);
    const elsewhere = await howToUpdateSoon("devin", found("/opt/homebrew/bin/devin"), env);
    assert.ok(elsewhere instanceof Unable);
    assert.deepEqual([elsewhere.key, elsewhere.args], ["station.updates.devinElsewhere", { path: "/opt/homebrew/bin/devin" }]);
    assert.ok(say_(elsewhere).includes("/opt/homebrew/bin/devin"));
    assert.deepEqual(await howToInstallSoon("devin", bare), machine.devinInstall);
    assert.equal((await howToInstallSoon("devin", bare) as any).program, WINDOWS ? "powershell" : "/bin/sh");
    assert.equal(kindPackage("devin"), "", "no npm package");
    // The Antigravity CLI by its own installer; it updates itself.
    assert.deepEqual(await howToInstallSoon("agy", bare), machine.agyInstall);
    assert.equal((await howToInstallSoon("agy", bare) as any).program, WINDOWS ? "powershell" : "/bin/sh");
    const agy = found("/Users/a/.local/bin/agy");
    assert.deepEqual(await howToUpdateSoon("agy", agy, env), { program: agy.onPath, args: ["update"] });
  });

  test("a command's failure shown as its last lines, without a terminal's escapes and a progress bar's returns", () => {
    const said = "\u001b[0;32m✓\u001b[0m Installed devin\n##   44.4%\r####   95.5%\r#####  100.0%\n\u001b[1A\u001b[2KError: Login canceled\n\u001b[?2004l";
    assert.equal(tail(said, "en"), "✓ Installed devin\n#####  100.0%\nError: Login canceled");
  });
});

// One at a time (the tests above run side by side): each points TMPDIR at a directory of its own, and hears the log.
describe("the station's update by a delta", { skip: WINDOWS && "install.sh is macOS's and Linux's" }, () => {
  const shInstaller = {};
  /// A station installed from release 1300 (its files as its archive had them: BUILD, station/main.js, the installer;
  /// then what the installer put beside them, CHANNEL and the link to its Node), the next release 1310 and the delta
  /// between them; the cloud serves the feed `feed` makes of them, and the delta at /releases/station/next.delta
  /// (`body`: what it answers instead). Temporary files in a temporary directory of the test's own (TMPDIR).
  async function deltaCase(t: { after: (f: () => unknown) => void; signal: AbortSignal }, feed: (r: ReturnType<typeof nextRelease>) => object, body?: (r: ReturnType<typeof nextRelease>) => Said | Promise<Said>) {
    const dir = temp();
    const tmp = join(dir, "tmp");
    mkdirSync(tmp);
    const before = process.env.TMPDIR;
    process.env.TMPDIR = tmp;
    t.after(() => (before === undefined ? delete process.env.TMPDIR : (process.env.TMPDIR = before)));
    const data = join(dir, "data");
    let release: ReturnType<typeof nextRelease> | null = null;
    const [origin, server, asked, , installer] = await cloudWithRelease("0.1.1310", "1310", false, undefined, {
      "station.json": () => ({ body: JSON.stringify(feed(release!)) }),
      "station/next.delta": () => (body ? body(release!) : { type: "application/octet-stream", body: release!.delta }),
    });
    t.after(() => server.close());
    const updates = installed(data, "1300", "stable\n", { origin: () => origin, env: { PATH: "/usr/bin:/bin" } }, installer);
    t.after(() => updates.close());
    mkdirSync(join(data, "app", "station"));
    writeFileSync(join(data, "app", "station", "main.js"), programBytes(200_000));
    release = nextRelease(join(dir, "release"), join(data, "app"));
    writeFileSync(join(data, "app", "CHANNEL"), "stable\n");
    symlinkSync(join(dir, "node"), join(data, "app", "node"));
    const lines: Line[] = [];
    hearLines((l) => void (l.at === "updates" && lines.push(l)));
    t.after(() => hearLines(null));
    const run = async () => {
      await updates.check();
      await updates.update("station", "zh");
      await until("ended", () => station(updates).state !== "updating", t.signal);
      const [saw] = readFileSync(join(data, "installer-saw"), "utf8").trim().split("\n").slice(1);
      return { told: saw!.split(" ")[1], handed: existsSync(join(data, "handed")) ? readFileSync(join(data, "handed")) : null };
    };
    return { data, tmp, origin, asked, updates, lines, release: release!, run };
  }

  test("with a delta from the build it runs, the station makes the release's raw archive and hands it to the installer", shInstaller, async (t) => {
    const c = await deltaCase(t, (r) => withDeltas(feedOf(1310, r.build), [r.entry(1290, "station/other.delta"), r.entry(1300)]));
    const { told, handed } = await c.run();
    assert.equal(station(c.updates).done, "已更新到 0.1.1310，agent 未中断");
    // What it made is the tar inside the release's .tar.gz, byte for byte, and the installer checks it by its hash.
    assert.ok(handed !== null && handed.equals(c.release.raw), "the raw archive handed");
    assert.equal(told, c.release.build.rawSha256);
    assert.ok(c.asked.includes("/releases/station/next.delta"), c.asked.join());
    assert.ok(!c.asked.includes("/releases/station/other.delta"), "only the delta from its own build");
    assert.ok(c.lines.some((l) => l.message === "the release made from a delta"), c.lines.map((l) => l.message).join());
    // Nothing left of it but what the installer took.
    assert.deepEqual(readdirSync(c.tmp), []);
  });

  test("while it takes the delta, the update is answered as started and shows the download", shInstaller, async (t) => {
    let send = () => {};
    const sent = new Promise<void>((r) => (send = r));
    const c = await deltaCase(t, (r) => withDeltas(feedOf(1310, r.build), [r.entry(1300)]), async (r) => {
      await sent;
      return { type: "application/octet-stream", body: r.delta };
    });
    await c.updates.check();
    await c.updates.update("station", "zh");
    await until("asked for the delta", () => c.asked.includes("/releases/station/next.delta"), t.signal);
    const line = station(c.updates);
    assert.equal(line.state, "updating");
    assert.equal(line.percent, 0);
    assert.equal(line.progress, tr("zh", "station.updates.downloadingStation"), "the installer's download step, as the pages say it");
    assert.ok(!existsSync(join(c.data, "installer-ran")), "the installer waits for it");
    await assert.rejects(c.updates.update("station", "zh"), (e: Error) => e.message === "Station 正在更新");
    send();
    await until("ended", () => station(c.updates).state === "idle", t.signal);
    assert.ok(readFileSync(join(c.data, "handed")).equals(c.release.raw));
  });

  test("a delta that cannot be used is a line in the log, and the installer downloads the release as without one", shInstaller, async (t) => {
    const cases: [string, (r: ReturnType<typeof nextRelease>) => object, ((r: ReturnType<typeof nextRelease>) => Said)?, ((data: string) => void)?][] = [
      // Its bytes broken after it was made, the feed saying their hash: it does not apply.
      ["a corrupt delta", (r) => {
        const bad = Buffer.from(r.delta);
        bad[bad.length - 20] = bad[bad.length - 20]! ^ 0xff;
        return withDeltas(feedOf(1310, r.build), [r.entry(1300, "station/next.delta", bad)]);
      }, (r) => {
        const bad = Buffer.from(r.delta);
        bad[bad.length - 20] = bad[bad.length - 20]! ^ 0xff;
        return { type: "application/octet-stream", body: bad };
      }],
      ["a delta whose hash is not the feed's", (r) => withDeltas(feedOf(1310, r.build), [{ ...r.entry(1300), sha256: SHA_A }])],
      ["a delta of another size than the feed says", (r) => withDeltas(feedOf(1310, r.build), [{ ...r.entry(1300), size: r.delta.length - 1 }])],
      ["a delta not found", (r) => withDeltas(feedOf(1310, r.build), [r.entry(1300, "station/gone.delta")])],
      // The release installed is not the one the delta is from (a file changed since).
      ["an installed release that differs", (r) => withDeltas(feedOf(1310, r.build), [r.entry(1300)]), undefined,
        (data) => writeFileSync(join(data, "app", "station", "main.js"), programBytes(200_000, 2))],
    ];
    for (const [name, feed, body, change] of cases) {
      await t.test(name, async (t) => {
        const c = await deltaCase(t, feed, body);
        change?.(c.data);
        const { told, handed } = await c.run();
        assert.equal(station(c.updates).done, "已更新到 0.1.1310，agent 未中断", name);
        assert.equal(handed, null, "nothing handed");
        assert.equal(told, c.release.build.sha256, "the whole archive's hash");
        const warned = c.lines.find((l) => l.message === "the delta not used: the installer downloads the whole release");
        assert.ok(warned && typeof warned.fields?.why === "string", c.lines.map((l) => l.message).join());
        assert.deepEqual(readdirSync(c.tmp), [], "nothing left of it");
      });
    }
  });

  test("a delta is not tried for another build, nor for a release whose signed words say no raw archive", shInstaller, async (t) => {
    for (const [name, feed] of [
      ["from another build", (r: ReturnType<typeof nextRelease>) => withDeltas(feedOf(1310, r.build), [r.entry(1299)])],
      ["no raw archive signed", (r: ReturnType<typeof nextRelease>) => withDeltas(feedOf(1310, { sha256: r.build.sha256, size: r.build.size }), [r.entry(1300)])],
      ["not well formed", (r: ReturnType<typeof nextRelease>) => withDeltas(feedOf(1310, r.build), [{ ...r.entry(1300), file: "../station.json" }])],
      ["no smaller than the archive", (r: ReturnType<typeof nextRelease>) => withDeltas(feedOf(1310, r.build), [{ ...r.entry(1300), size: r.build.size }])],
    ] as const) {
      await t.test(name, async (t) => {
        const c = await deltaCase(t, feed);
        const { told, handed } = await c.run();
        assert.equal(handed, null);
        assert.equal(told, c.release.build.sha256);
        assert.ok(!c.asked.some((a) => a.endsWith(".delta")), c.asked.join());
        assert.ok(!c.lines.some((l) => l.message.startsWith("the delta not used")), "nothing to say: none was tried");
      });
    }
  });
});

describe("going back to a release before the one the station runs", { skip: WINDOWS && "install.sh is macOS's and Linux's" }, () => {
  const shInstaller = {};
  const here = npmPlatform() ?? "darwin-arm64";
  const archiveOf = (build: number) => Buffer.from(`the archive of ${build}`);
  const shaOf = (b: Buffer) => createHash("sha256").update(b).digest("hex");
  const builtAs = (build: number) => ({ sha256: shaOf(archiveOf(build)), size: archiveOf(build).length });
  const kept = (build: number) => `station/archive/stable/${build}-${shaOf(archiveOf(build))}-${here}.tar.gz`;

  /// A station on 1300 (updating by itself when `auto`), the stable feed's latest (`latest`, 1310) naming before it `earlier`
  /// (default: 1300, 1290, 1280 signed by a key no station takes, 1270 with no build for this machine), each archive
  /// under its own name (`archive`: what the cloud answers for it instead); the installer puts `to`'s BUILD in place.
  async function backCase(t: { after: (f: () => unknown) => void; signal: AbortSignal }, o: { auto?: boolean; latest?: string; to?: string; earlier?: object[]; archive?: (build: number) => Said } = {}) {
    const dir = temp();
    const tmp = join(dir, "tmp");
    mkdirSync(tmp);
    const before = process.env.TMPDIR;
    process.env.TMPDIR = tmp;
    t.after(() => (before === undefined ? delete process.env.TMPDIR : (process.env.TMPDIR = before)));
    const data = join(dir, "data");
    const earlier = o.earlier ?? [feedOf(1300, builtAs(1300)), feedOf(1290, builtAs(1290)), feedOf(1280, builtAs(1280), OTHER), { ...feedOf(1270), ...signedFor(1270, "no-such-machine") }];
    const files: Record<string, () => Said> = {};
    for (const b of [1300, 1290, 1280, 1270]) files[kept(b)] = () => (o.archive ? o.archive(b) : { type: "application/gzip", body: archiveOf(b) });
    const latest = o.latest ?? "0.1.1310";
    const [origin, server, asked, , installer] = await cloudWithRelease(latest, (o.to ?? "0.1.1290").split(".").at(-1)!, false, withEarlier(feedOf(Number(latest.split(".").at(-1))), earlier), files);
    t.after(() => server.close());
    const updates = installed(data, "1300", "stable\n", { origin: () => origin, env: { PATH: "/usr/bin:/bin" } }, installer);
    t.after(() => updates.close());
    // (on once its feed is read: on before, it would update itself to the latest as it reads it)
    const check = async () => {
      await updates.check();
      if (o.auto) new ConfigFile(data).update((raw) => (raw.autoUpdate = true));
    };
    const lines: Line[] = [];
    hearLines((l) => void (l.at === "updates" && lines.push(l)));
    t.after(() => hearLines(null));
    return { data, tmp, asked, updates, lines, check, config: () => new ConfigFile(data).raw() as Record<string, unknown> };
  }
  /// Release `build`'s words signed with only `platform`'s build in them.
  const signedFor = (build: number, platform: string) => {
    const f = feedOf(build) as any;
    const w = JSON.parse(Buffer.from(f.release, "base64").toString("utf8"));
    w.builds = { [platform]: w.builds[here] };
    return signedWords(w);
  };

  test("the releases it can go back to: those its feed names before the latest that verify, older than its own, built for this machine", async (t) => {
    const c = await backCase(t);
    await c.check();
    const line = station(c.updates);
    assert.deepEqual(line.earlier, ["0.1.1290"]);
    assert.ok(c.lines.some((l) => l.message === "releases before the latest do not verify: not offered"), c.lines.map((l) => l.message).join());
    // None where the feed names none, nor a line of a runtime.
    const bare = await backCase(t, { earlier: [] });
    await bare.check();
    assert.equal(station(bare.updates).earlier, undefined);
    assert.ok(bare.updates.get("zh").every((l) => l.earlier === undefined));
  });

  test("gone back to: its archive downloaded and checked here, handed to the installer, updating by itself off until a release newer than the one left", shInstaller, async (t) => {
    // (the release it left the latest: one newer out would turn updating by itself on again as the station reads what is
    // out after going back, and update it to that)
    const c = await backCase(t, { auto: true, latest: "0.1.1300" });
    await c.check();
    await c.updates.update("station", "zh", "0.1.1290");
    await until("ended", () => station(c.updates).state !== "updating", t.signal);
    await until("read after going back", () => station(c.updates).version === "0.1.1290", t.signal);
    const [, saw] = readFileSync(join(c.data, "installer-saw"), "utf8").trim().split("\n");
    assert.equal(saw!.split(" ")[1], shaOf(archiveOf(1290)), "told the signed hash of the release gone back to");
    assert.ok(readFileSync(join(c.data, "handed")).equals(archiveOf(1290)), "handed its archive");
    assert.ok(c.asked.includes(`/releases/${kept(1290)}`), c.asked.join());
    assert.equal(readFileSync(join(c.data, "app", "BUILD"), "utf8").trim(), "1290");
    assert.equal(c.config().autoUpdate, false);
    assert.equal(c.config().autoUpdateAfter, "0.1.1300");
    assert.deepEqual(readdirSync(c.tmp), [], "nothing left of it");
    // The pages say so, and it does not update itself back to the release it left.
    assert.equal(c.updates.stationWith("0.1.1300").autoAfter, "0.1.1300");
    assert.equal(c.updates.toUpdateTo(), null);
  });

  test("station_version: what the agents see of the release, and going back by it", shInstaller, async (t) => {
    const c = await backCase(t);
    await c.check();
    // (asked in English, as agents are: the release's English installer)
    writeFileSync(join(c.data, "app", "bin", "install.en.sh"), readFileSync(join(c.data, "app", "bin", "install.zh.sh")));
    const [tool] = versionTools(c.updates);
    const listed = JSON.parse(await tool!.run("s", { action: "list" }));
    assert.deepEqual(listed, { version: "0.1.1300", latest: "0.1.1310", newer: true, channel: "stable", auto: false, autoAfter: null, earlier: ["0.1.1290"], state: "idle" });
    await assert.rejects(tool!.run("s", { action: "back" }), /to: a version list names in earlier/);
    await assert.rejects(tool!.run("s", { action: "back", to: "0.1.1250" }), (e: Error) => e.message === tr("en", "station.updates.backUnknown", { version: "0.1.1250" }));
    await assert.rejects(tool!.run("s", { action: "other" }), /action: list, update, back or wait/);
    const started = JSON.parse(await tool!.run("s", { action: "back", to: "0.1.1290" }));
    assert.equal(started.started, true);
    await until("ended", () => station(c.updates).state !== "updating", t.signal);
    assert.equal(readFileSync(join(c.data, "app", "BUILD"), "utf8").trim(), "1290");
  });

  test("updating by itself, off since it went back, is on again once the latest is newer than the release it left", async (t) => {
    const dir = temp();
    const updates = installed(dir, "1290", "stable\n");
    t.after(() => updates.close());
    new ConfigFile(dir).update((raw) => {
      raw.autoUpdate = false;
      raw.autoUpdateAfter = "0.1.1300";
    });
    for (const [latest, on] of [["0.1.1300", false], ["0.1.1310", true]] as const) {
      updates.stationWith(latest);
      await updates.resumeAutoForTests();
      assert.equal(updates.auto(), on, latest);
    }
    assert.equal((new ConfigFile(dir).raw() as Record<string, unknown>).autoUpdateAfter, undefined);
    assert.equal(updates.toUpdateTo(), "0.1.1310");
    // Turned on or off by someone meanwhile: what they said, and nothing kept of the release left.
    new ConfigFile(dir).update((raw) => {
      raw.autoUpdate = false;
      raw.autoUpdateAfter = "0.1.1300";
    });
    await updates.setAuto(false, "zh").catch(() => {});
    assert.equal((new ConfigFile(dir).raw() as Record<string, unknown>).autoUpdateAfter, undefined);
  });

  test("refused: a release its feed does not name or that does not verify, one not older, a runtime", shInstaller, async (t) => {
    const c = await backCase(t);
    await c.check();
    await assert.rejects(c.updates.update("station", "zh", "0.1.1250"), (e: Error) => e.message === tr("zh", "station.updates.backUnknown", { version: "0.1.1250" }));
    await assert.rejects(c.updates.update("station", "zh", "0.1.1280"), (e: Error) => e.message === tr("zh", "station.updates.backUnknown", { version: "0.1.1280" }), "signed by a key it does not take");
    await assert.rejects(c.updates.update("station", "zh", "0.1.1300"), (e: Error) => e.message === tr("zh", "station.updates.backNotOlder", { version: "0.1.1300", current: "0.1.1300" }));
    await assert.rejects(c.updates.update("station", "zh", "0.1.1270"), (e: Error) => e.message === tr("zh", "station.updates.noBuild", { version: "0.1.1270" }));
    await assert.rejects(c.updates.update("claude", "zh", "0.1.1290"), (e: Error) => e.message === tr("zh", "station.updates.backStationOnly"));
    assert.equal(station(c.updates).state, "idle");
    assert.ok(!existsSync(join(c.data, "installer-ran")));
  });

  test("an archive not the one its words sign: not gone back, said why, nothing installed and updating by itself as it was", shInstaller, async (t) => {
    for (const [name, archive] of [
      ["another archive", () => ({ type: "application/gzip", body: Buffer.from("something else") })],
      ["not there", () => null],
    ] as [string, (b: number) => Said][]) {
      await t.test(name, async (t) => {
        const c = await backCase(t, { auto: true, archive });
        await c.check();
        await c.updates.update("station", "zh", "0.1.1290");
        await until("ended", () => station(c.updates).state !== "updating", t.signal);
        const line = station(c.updates);
        assert.equal(line.state, "failed");
        assert.ok(line.message?.startsWith("0.1.1290 下载失败，没有退回："), line.message);
        assert.ok(!existsSync(join(c.data, "installer-ran")), "the installer not run (it would install the latest)");
        assert.equal(c.config().autoUpdate, true);
        assert.equal(c.config().autoUpdateAfter, undefined);
        assert.deepEqual(readdirSync(c.tmp), [], "nothing left of it");
      });
    }
  });
});

// Every tell reaches `events.overviewChanged`, which sends each connected stream its whole overview: a download is told
// at its start, its end and at most every PROGRESS_NOTIFY_MS (2 s) between, while what is read has its latest percent.
describe("a download's progress told at most every two seconds", () => {
  type Internal = {
    items: Record<string, { updating: number | null; step: string | null; percent: number | null }>;
    set(kind: string, f: (i: { step: string | null; percent: number | null }) => void): void;
    sayStationPercent(percent: number): void;
    sayDownloading(kind: string, version: string, got: number, total: number | null): void;
    say(kind: string, progress: unknown, percent: number | null): void;
  };
  const paced = (t: { after: (f: () => unknown) => void }, line: number) => {
    const time = testClock();
    const updates = installed(temp(), "1300", null, { clock: time.clock });
    t.after(() => updates.close());
    const told: (number | undefined)[] = [];
    updates.changes(() => told.push(updates.get("zh")[line]!.percent));
    return { time, updates, told, internal: updates as unknown as Internal };
  };
  const pass = async (time: ReturnType<typeof testClock>, ms: number) => {
    await time.adjust(ms);
    await settle(5);
  };

  test("the station's delta: 0% and 100% at once, the percents between once each two seconds, a step at once", async (t) => {
    const { time, updates, told, internal } = paced(t, 0);
    internal.items.station!.updating = 0;
    internal.items.station!.step = "download";
    internal.sayStationPercent(0);
    assert.deepEqual(told, [0], "its start at once");
    for (let p = 1; p < 100; p++) internal.sayStationPercent(p);
    assert.deepEqual(told, [0], "the percents between held back");
    assert.equal(station(updates).percent, 99, "what is read has the latest");
    internal.sayStationPercent(100);
    assert.deepEqual(told, [0, 100], "its end at once");
    await pass(time, 2_000);
    assert.deepEqual(told, [0, 100], "nothing held back left after the end");

    told.length = 0;
    internal.sayStationPercent(0);
    for (let p = 1; p <= 40; p++) internal.sayStationPercent(p);
    assert.deepEqual(told, [0]);
    await pass(time, 1_999);
    assert.deepEqual(told, [0], "not before two seconds");
    await pass(time, 1);
    assert.deepEqual(told, [0, 40], "the latest, two seconds after the one before");
    for (let p = 41; p <= 60; p++) internal.sayStationPercent(p);
    assert.deepEqual(told, [0, 40]);
    internal.set("station", (i) => {
      i.step = "handoff";
      i.percent = null;
    });
    assert.deepEqual(told, [0, 40, undefined], "the next step at once");
    await pass(time, 2_000);
    assert.deepEqual(told, [0, 40, undefined], "the percent held back is not told after the step");
  });

  test("a runtime's download: its start, 100% and installing at once, the sizes between once each two seconds", async (t) => {
    const { time, updates, told, internal } = paced(t, 2);
    internal.items.codex!.updating = 0;
    const mb = 1024 * 1024;
    internal.sayDownloading("codex", "0.47.0", 0, 100 * mb);
    assert.deepEqual(told, [0], "its start at once");
    for (let got = 1; got < 50; got++) internal.sayDownloading("codex", "0.47.0", got * mb, 100 * mb);
    assert.deepEqual(told, [0]);
    assert.equal(updates.get("zh")[2]!.percent, 49, "what is read has the latest");
    await pass(time, 2_000);
    assert.deepEqual(told, [0, 49], "the latest, two seconds after its start");
    for (let got = 50; got < 100; got++) internal.sayDownloading("codex", "0.47.0", got * mb, 100 * mb);
    assert.deepEqual(told, [0, 49]);
    internal.sayDownloading("codex", "0.47.0", 100 * mb, 100 * mb);
    assert.deepEqual(told, [0, 49, 100], "its end at once");
    internal.say("codex", INSTALLING, null);
    assert.deepEqual(told, [0, 49, 100, undefined], "installing at once");
    assert.equal(updates.get("zh")[2]!.progress, say(INSTALLING, "zh"));
    await pass(time, 2_000);
    assert.equal(told.length, 4, "nothing held back left");
  });
});
