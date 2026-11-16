// What the station's main thread waits on as its updates run (src/updates/): the software page's reading (`get`, and
// `check`: the station's signed feed, every runtime's version and latest, Cursor's SDK), a runtime installed with a
// Node of the station's own (nodejs.org's build downloaded, checked, unpacked and put on its PATH), the station's own
// update followed from its download's percent to its end, and `stillfail-station channel` asking the running station
// (run/channel-ask, SIGHUP, run/channel-answer): none of node:fs's or node:zlib's synchronous calls (station/AGENTS.md,
// the main thread waits on nothing). Each ran on every look at the software page, every install and every update.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdirSync, mkdtempSync, readFileSync, readdirSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { after, test } from "node:test";
import { ConfigFile } from "../src/ops/config.ts";
import { WINDOWS, platform as machine } from "../src/platform/index.ts";
import { setChannel } from "../src/updates/channel.ts";
import { Updates, type UpdatesOptions } from "../src/updates/updates.ts";
import { script } from "./accounts-fakes.ts";
import { syncCalls } from "./main-thread-sync.ts";
import { feedOf, trusted } from "./release-fakes.ts";

delete process.env.STILLFAIL_CONFIG;

const dirs: string[] = [];
const servers: Server[] = [];
const configs: ConfigFile[] = [];
after(async () => {
  for (const s of servers) s.close();
  for (const c of configs) c.unwatch();
  await Promise.all(configs.map((c) => c.written()));
  for (const d of dirs) rmSync(d, { recursive: true, force: true });
});
function scratch(): string {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), "updates-main-thread-")));
  dirs.push(dir);
  return dir;
}

/// A server answering `route` (null: 404).
type Said = { type?: string; body: string | Buffer } | null;
async function serve(route: (path: string) => Said | Promise<Said>): Promise<string> {
  const server = createServer(async (req, res) => {
    const said = await route(new URL(req.url ?? "/", "http://x").pathname);
    if (said === null) return void res.writeHead(404).end("no");
    const body = typeof said.body === "string" ? Buffer.from(said.body) : said.body;
    res.writeHead(200, { "content-type": said.type ?? "application/json", "content-length": body.length }).end(body);
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  servers.push(server);
  return `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
}

/// A station installed by the installer in `data` (BUILD 1300, from the stable channel, carrying `installer`), its
/// config watched as the station's is (services.ts): what the pages read of it is in memory.
function installed(data: string, more: Partial<UpdatesOptions>, installer?: string): Updates {
  const app = join(data, "app");
  mkdirSync(join(app, "bin"), { recursive: true });
  writeFileSync(join(app, "BUILD"), "1300");
  writeFileSync(join(app, "CHANNEL"), "stable");
  if (installer !== undefined) writeFileSync(join(app, "bin", "install.zh.sh"), installer);
  const config = new ConfigFile(data);
  config.watch();
  configs.push(config);
  return new Updates({ app, data, config, origin: () => null, env: { PATH: "/nowhere" }, trusted, timing: { followLook: 200 }, ...more });
}

/// Until `updates` says what `f` holds: told by its changes, no clock.
const until = (updates: Updates, f: () => boolean) =>
  new Promise<void>((resolve) => {
    if (f()) return resolve();
    const stop = updates.changes(() => {
      if (!f()) return;
      stop();
      resolve();
    });
  });

const line = (updates: Updates, id: string) => updates.get("zh").find((l) => l.id === id)!;

test("the software page's reading waits on no file: the station's feed, each runtime's version and latest, Cursor's SDK", { skip: WINDOWS && "the runtimes' stand-ins are shell scripts" }, async (t) => {
  const dir = scratch();
  const [data, bin] = [join(dir, "data"), join(dir, "bin")];
  const latest: Record<string, string> = {
    "/@anthropic-ai/claude-code/latest": "2.1.300", "/@openai/codex/latest": "0.47.0", "/@deepseek-ai/dsh/latest": "1.2.0",
    "/@xai-official/grok/latest": "1.0.62", "/@cursor/sdk/latest": "0.9.0", "/@earendil-works/pi-coding-agent/latest": "0.40.0",
  };
  const base = await serve((path) =>
    path === "/releases/station.json" ? { body: JSON.stringify(feedOf(1310)) }
    : path === "/devin.json" ? { body: JSON.stringify({ version: "3000.12.0", platforms: {} }) }
    : latest[path] ? { body: JSON.stringify({ version: latest[path] }) }
    : null);
  // Each runtime on PATH says its version; npm and brew are there to be found.
  mkdirSync(bin, { recursive: true });
  for (const [name, said] of [["claude", "2.1.284 (Claude Code)"], ["codex", "codex-cli 0.46.0"], ["dsh", "dsh 1.1.0"], ["grok", "grok 1.0.61"], ["devin", "devin 3000.11.0"], ["pi", "0.39.0"], ["agy", "agy 1.0.0"], ["hermes", "hermes 0.1.0"], ["npm", "10.9.0"], ["brew", "Homebrew 4.6.0"]]) {
    script(join(bin, name!), `#!/bin/sh\necho "${said}"\n`);
  }
  // Cursor's SDK where npm put it in the station's prefix.
  const sdk = join(data, "runtimes", "cursor", "lib", "node_modules", "@cursor", "sdk");
  mkdirSync(sdk, { recursive: true });
  writeFileSync(join(sdk, "package.json"), JSON.stringify({ name: "@cursor/sdk", version: "0.8.0" }));
  const updates = installed(data, { origin: () => base, registry: base, devinManifest: `${base}/devin.json`, env: { PATH: `${bin}:/usr/bin:/bin`, HOME: dir } });
  t.after(() => updates.close());

  assert.deepEqual(await syncCalls(async () => {
    await updates.check();
    updates.get("zh");
    updates.get("en");
    updates.channel();
  }), []);
  assert.deepEqual([line(updates, "station").latest, line(updates, "station").newer, line(updates, "station").channel], ["0.1.1310", true, "stable"]);
  assert.deepEqual([line(updates, "codex").version, line(updates, "codex").latest, line(updates, "codex").newer], ["0.46.0", "0.47.0", true]);
  assert.deepEqual([line(updates, "cursor").version, line(updates, "cursor").latest], ["0.8.0", "0.9.0"]);
  assert.deepEqual([line(updates, "devin").version, line(updates, "devin").latest], ["3000.11.0", "3000.12.0"]);
  // A release with no CHANNEL (from before there were channels): the pages' reading of the channel looks at no file.
  rmSync(join(data, "app", "CHANNEL"));
  const before = installed(join(dir, "older"), {});
  rmSync(join(dir, "older", "app", "CHANNEL"));
  t.after(() => before.close());
  assert.deepEqual(await syncCalls(async () => {
    updates.channel();
    before.channel();
    before.get("zh");
  }), []);
});

test("a runtime installed with the station's own Node waits on no file: its download, checksum, unpacking and PATH", { skip: WINDOWS && "the Node's npm stand-in is a shell script" }, async (t) => {
  const version = "24.22.1";
  const dir = scratch();
  const build = machine.nodeBuild(version)!;
  // nodejs.org's build for this machine: an npm that installs Grok Build in the prefix it is given.
  const nodes = join(dir, "nodes");
  mkdirSync(join(nodes, build.dist, build.bin), { recursive: true });
  // (a tree of many files, as a Node's is: what is left of an unpacking is removed off the thread)
  for (let i = 0; i < 200; i++) {
    const at = join(nodes, build.dist, "lib", `m${i % 20}`, `f${i}.js`);
    mkdirSync(dirname(at), { recursive: true });
    writeFileSync(at, "//\n");
  }
  script(join(nodes, build.dist, build.bin, "npm"), `#!/bin/sh
prefix=
while [ $# -gt 0 ]; do [ "$1" = --prefix ] && prefix="$2"; shift; done
pkg="$prefix/lib/node_modules/@xai-official/grok"
mkdir -p "$pkg/bin" "$prefix/bin"
printf '#!/bin/sh\\necho "grok 1.0.62 (1474f9cb)"\\n' > "$pkg/bin/grok"
chmod +x "$pkg/bin/grok"
ln -s ../lib/node_modules/@xai-official/grok/bin/grok "$prefix/bin/grok"
echo "added 1 package"
`);
  const archive = join(dir, build.archive);
  execFileSync(build.tar, ["-z", "-cf", archive, "-C", nodes, build.dist]);
  const bytes = readFileSync(archive);
  const sums = `${createHash("sha256").update(bytes).digest("hex")}  ${build.archive}\n`;
  const base = await serve((path) =>
    path === "/@xai-official/grok/latest" ? { body: JSON.stringify({ version: "1.0.62" }) }
    : path === `/dist/v${version}/SHASUMS256.txt` ? { type: "text/plain", body: sums }
    : path === `/dist/v${version}/${build.archive}` ? { type: "application/octet-stream", body: bytes }
    : null);
  const data = join(dir, "data");
  const env = { PATH: "/usr/bin:/bin", HOME: dir };
  const updates = installed(data, { registry: base, devinManifest: base, nodeDist: `${base}/dist`, env });
  writeFileSync(join(data, "app", "NODE_VERSION"), `${version}\n`);
  // An unpacking a station stopped in the middle of: removed before this one.
  mkdirSync(join(data, "node", `.unpacking-${build.dist}`, "left", "over"), { recursive: true });
  t.after(() => updates.close());
  const grok = () => line(updates, "grok");

  assert.deepEqual(await syncCalls(async () => {
    await updates.check();
    assert.deepEqual([grok().installed, grok().updatable], [false, true]);
    await updates.update("grok", "zh");
    await until(updates, () => grok().state !== "updating");
  }), []);
  assert.deepEqual([grok().installed, grok().version, grok().state, grok().message], [true, "1.0.62", "idle", undefined]);
  assert.ok(env.PATH.endsWith(join(data, "node", build.dist, build.bin)), env.PATH);
});

test("the station's update followed from its download to its end waits on no file", { skip: WINDOWS && "a shell installer" }, async (t) => {
  const dir = scratch();
  const data = join(dir, "data");
  let finish = () => {};
  const finished = new Promise<void>((r) => (finish = r));
  const base = await serve((path) =>
    path === "/releases/station.json" ? { body: JSON.stringify(feedOf(1310)) }
    : path === "/download" ? finished.then(() => ({ type: "text/plain", body: "" }))
    : null);
  // The installer as the real one goes: its download (curl's bar in update.log), the handover, the next BUILD.
  const installer = `#!/bin/sh
set -eu
run="$STILLFAIL_DATA/run"
printf 'download\\n' > "$run/update.step"
echo "### 37.2%"
curl -fsS "${base}/download" > /dev/null
printf 'handoff\\n' > "$run/update.step"
printf '1310\\n' > "$STILLFAIL_DATA/app/BUILD"
`;
  mkdirSync(data, { recursive: true });
  const updates = installed(data, { origin: () => base, stationOnly: true, env: { PATH: "/usr/bin:/bin" } }, installer);
  t.after(() => updates.close());
  // A test of its own: the station's line only.
  const station = () => updates.get("zh")[0]!;

  assert.deepEqual(await syncCalls(async () => {
    await updates.check();
    await updates.update("station", "zh");
    await until(updates, () => station().percent === 37);
    finish();
    await until(updates, () => station().state === "idle");
  }), []);
  assert.equal(station().done, "已更新到 0.1.1310，agent 未中断");
  assert.equal(readFileSync(join(data, "run", "update.exit"), "utf8").trim(), "0");
});

test("`stillfail-station channel` asking the running station, and its answer, wait on no file", { skip: WINDOWS && "no signals on Windows" }, async (t) => {
  const dir = scratch();
  const data = join(dir, "data");
  const runDir = join(data, "run");
  mkdirSync(runDir, { recursive: true });
  // This process plays the station: its file saying it takes the ask, SIGHUP taken (the launcher's `hup`).
  writeFileSync(join(runDir, "station.json"), JSON.stringify({ pid: process.pid, drain: 1, channel: 1 }));
  const updates = installed(data, { stationOnly: true });
  t.after(() => updates.close());
  // (what it reads again on the channel it is put on is the cloud's: none here)
  updates.check = async () => {};
  const hup = () => void updates.answerChannelAsk();
  process.on("SIGHUP", hup);
  t.after(() => void process.off("SIGHUP", hup));

  const calls = await syncCalls(async () => {
    await setChannel(data, "beta", 10_000, () => true);
  });
  assert.equal(updates.channel(), "beta");
  // The answer taken, the ask gone: nothing left for the next.
  assert.deepEqual(readdirSync(runDir).filter((f) => f.startsWith("channel-")), []);
  // The config kept with the channel is written off the thread too (ops/config.ts `updateSoon`).
  assert.deepEqual(calls, []);
});
