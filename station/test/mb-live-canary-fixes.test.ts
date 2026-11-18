// What the MoonBit station's first live canaries found wrong, held through the program's parts (station/mb
// src/station_main, `stillfail-reader --builder harness-station-main`, harness.mbt): a driver's words said by their key
// in the station's language (live_p5_2_io.mbt `said_of`), the log's lines one a line with their time (live_p5_1.mbt
// `p51_log`, `noted`), a tree's size measured by the footprint builder in a process of its own (live_p5_3_remote.mbt
// `p53_tree_bytes`), and still.fail Helper asked over the shell's Unix socket (screens/host_io.mbt: a connection's close
// told after its owner took its answer), one left holding its lock with no socket ended before the next is launched
// (live_p5_4_screens.mbt `p54_helper_launch`). A job followed again through a restart (its start as the system says
// it, against the wall's time it was kept at) is mb-live-p5-3.test.ts's, beside the station's other jobs.
import assert from "node:assert/strict";
import { type ChildProcess, spawn, spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { after, test } from "node:test";
import zhStation from "../../client/i18n/catalog/zh/station.json" with { type: "json" };
import enStation from "../../client/i18n/catalog/en/station.json" with { type: "json" };
import { mbReaderBinary } from "../src/read/mb-reader.ts";

const binary = mbReaderBinary();
const skip = binary === null ? "the MoonBit program (stillfail-reader) is not built here" : process.platform === "win32" ? "still.fail Helper's socket is a Unix socket" : false;

const dirs: string[] = [];
// (short: a Unix socket's path is at most 104 bytes on macOS)
const fresh = (what: string) => {
  const dir = mkdtempSync(join(tmpdir(), `sf-${what}-`));
  dirs.push(dir);
  return dir;
};
const children: ChildProcess[] = [];
const ended = (c: ChildProcess) => c.exitCode !== null || c.signalCode !== null;
const exited = (c: ChildProcess) => (ended(c) ? Promise.resolve() : new Promise<void>((r) => c.once("exit", () => r())));
after(async () => {
  const left = children.filter((c) => !ended(c));
  for (const c of left) c.kill("SIGKILL");
  await Promise.all(left.map(exited));
  for (const d of dirs) rmSync(d, { recursive: true, force: true });
});

/// The program's parts, a line a call; what it writes on stderr kept, and waited for by what it must say.
function harness() {
  const child = spawn(binary!, ["--builder", "harness-station-main", "--shell-dir", fresh("shell")], { stdio: ["pipe", "pipe", "pipe"] });
  children.push(child);
  let seq = 0;
  const waiting = new Map<number, (v: any) => void>();
  let stderr = "";
  const heard: (() => void)[] = [];
  child.stderr!.on("data", (d) => {
    stderr += d;
    for (const h of heard.splice(0)) h();
  });
  createInterface({ input: child.stdout! }).on("line", (line) => {
    const m = JSON.parse(line);
    waiting.get(m.id)?.(m);
    waiting.delete(m.id);
  });
  child.on("exit", (code) => {
    for (const w of waiting.values()) w({ error: `the harness ended (${code}): ${stderr}` });
  });
  const ok = async (op: string, a: Record<string, unknown> = {}) => {
    const said: any = await new Promise((resolve) => {
      seq += 1;
      waiting.set(seq, resolve);
      child.stdin!.write(`${JSON.stringify({ id: seq, op, ...a })}\n`);
    });
    assert.equal(said.error, undefined, `${op}: ${said.error}`);
    return said.ok;
  };
  /// stderr once it holds `words` (or the program ended).
  const said = async (words: string) => {
    while (!stderr.includes(words)) {
      if (ended(child)) assert.fail(`the harness ended before it said ${words}: ${stderr}`);
      await new Promise<void>((r) => heard.push(r));
    }
    return stderr;
  };
  return { child, ok, said };
}

test("a driver's words said by their key are said in the station's language, never as the key", { skip }, async () => {
  const { ok } = harness();
  for (const key of ["station.claudeAuth.machineRunsOut", "station.updates.codexMissingHostChat"]) {
    assert.equal(await ok("saidOf", { key, lang: "zh" }), (zhStation as Record<string, unknown>)[key]);
    assert.equal(await ok("saidOf", { key, lang: "en" }), (enStation as Record<string, unknown>)[key]);
  }
  // (an Ultrafast refusal's words: its key is the catalog's, never shown as it is)
  const ultrafast = await ok("saidOf", { key: "station.speed.ultrafast_unavailable", lang: "en" });
  assert.ok(!ultrafast.startsWith("station."), ultrafast);
  // What is not a key stays as it was said.
  assert.equal(await ok("saidOf", { key: "the runtime ended", lang: "zh" }), "the runtime ended");
});

test("the log's lines: one a line, each with its time, a part's notes as lines of the log", { skip }, async () => {
  const { ok, said } = harness();
  await ok("log", { level: "WARN", at: "session", message: "prompt failed" });
  await ok("noted", { text: "[browser] a chat's Farview tab taken up" });
  await ok("noted", { text: "[info] models: 12 listed" });
  await ok("noted", { text: "[WARN] runner: gone" });
  await ok("noted", { text: "error relay: refused" });
  await ok("noted", { text: "failed: Broken pipe (os error 32)\n" });
  await ok("noted", { text: "something bare" });
  const err = await said("something bare\n");
  const all = err.split("\n");
  assert.equal(all.pop(), "", "the last ends with its newline");
  const lines = all.slice(all.findIndex((l) => l.includes("prompt failed")));
  assert.ok(lines.every((l) => l !== ""), `no blank line: ${JSON.stringify(err)}`);
  const at = /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z /;
  assert.deepEqual(lines.map((l) => (at.test(l) ? l.replace(at, "") : `untimed: ${l}`)), [
  " WARN session: prompt failed",
  " INFO browser: a chat's Farview tab taken up",
  " INFO models: 12 listed",
  " WARN runner: gone",
  "ERROR relay: refused",
  " WARN runtime: Broken pipe (os error 32)",
  " INFO station: something bare",
  ]);
});

test("a tree's size is the footprint builder's, measured in a process of its own", { skip }, async () => {
  const { ok } = harness();
  const dir = fresh("tree");
  mkdirSync(join(dir, "a", "b"), { recursive: true });
  writeFileSync(join(dir, "one"), Buffer.alloc(10_000, 1));
  writeFileSync(join(dir, "a", "b", "two"), Buffer.alloc(70_000, 2));
  const bytes = await ok("treeBytes", { program: binary, path: dir });
  // The builder asked as tree_bytes asks it (jobs_host/remote.mbt), on its own.
  const builder = spawnSync(binary!, ["--builder", "footprint", "--sep", "/"], { input: `${JSON.stringify({ path: dir, maxEntries: 1_000_000, maxDurationMs: 60_000 })}\n`, encoding: "utf8" });
  const measured = JSON.parse(builder.stdout.split("\n")[0]!);
  assert.equal(bytes, measured.size);
  assert.ok(bytes >= 80_000, `${bytes}`);
  assert.equal(await ok("treeBytes", { program: binary, path: join(dir, "nowhere") }), 0);
});

/// A still.fail Helper of the test's, its command `node <…>/stillfail-helper.mjs <mode>`, its directory its socket's
/// (as the station gives it, `STILLFAIL_HELPER_SOCKET`): `held` holds the lock (its pid written in it, as the Helper
/// does now; `held-empty` leaves it empty, as one from before) with no socket; `serve` exits at once where one of them
/// is still there (the Helper's own lock refused), else answers on its socket.
const HELPER = `
import { createServer } from "node:net";
import { openSync, readFileSync, writeSync } from "node:fs";
import { dirname, join } from "node:path";
const dir = dirname(process.env.STILLFAIL_HELPER_SOCKET);
const mode = process.argv[2];
if (mode === "held" || mode === "held-empty") {
  const fd = openSync(join(dir, "helper.lock"), "w");
  if (mode === "held") writeSync(fd, process.pid + "\\n");
  writeSync(openSync(join(dir, "held.pid"), "w"), String(process.pid));
  process.stdout.write("held\\n");
  setInterval(() => {}, 1 << 30);
} else {
  const held = Number(readFileSync(join(dir, "held.pid"), "utf8"));
  try { process.kill(held, 0); process.exit(0); } catch {}
  const server = createServer((c) => {
    let got = "";
    c.on("data", (d) => {
      got += d;
      for (let at = got.indexOf("\\n"); at >= 0; at = got.indexOf("\\n")) {
        const ask = JSON.parse(got.slice(0, at));
        got = got.slice(at + 1);
        if (ask.op === "status") c.write(JSON.stringify({ ok: true, status: { screen: "granted", pid: process.pid } }) + "\\n");
        else if (ask.op === "quit") { c.end(JSON.stringify({ ok: true }) + "\\n", () => process.exit(0)); }
        else c.write(JSON.stringify({ ok: true }) + "\\n");
      }
    });
    c.on("error", () => {});
  });
  server.listen(process.env.STILLFAIL_HELPER_SOCKET);
}
`;

async function helperCase(mode: "held" | "held-empty") {
  const { ok } = harness();
  const dir = fresh("hl");
  const root = fresh("app");
  const app = join(root, "still.fail Helper.app");
  mkdirSync(join(app, "Contents", "MacOS"), { recursive: true });
  writeFileSync(join(app, "Contents", "Info.plist"), "<plist/>");
  writeFileSync(join(app, "Contents", "MacOS", "stillfail-helper"), "");
  // The Helper of now is the copy installed in its directory (its command names it); one from before, empty lock, is
  // found by `lsof` alone: its command names another place.
  const script = join(mode === "held" ? dir : root, "stillfail-helper.mjs");
  writeFileSync(script, HELPER);
  // One left from before: its lock held, its socket gone.
  const held = spawn(process.execPath, [script, mode], { stdio: ["ignore", "pipe", "ignore"], env: { ...process.env, STILLFAIL_HELPER_SOCKET: join(dir, "helper.sock") } });
  children.push(held);
  await new Promise<void>((resolve) => createInterface({ input: held.stdout! }).once("line", () => resolve()));
  const said = await ok("helperRequest", { program: binary, app, dir, launch: [process.execPath, script, "serve"], ask: { op: "status" } });
  assert.equal(said.ok, true, JSON.stringify(said));
  assert.equal(said.status.screen, "granted");
  await exited(held);
  assert.equal(held.signalCode, "SIGKILL", "the one holding the lock with no socket was ended");
}

test("still.fail Helper asked over its socket answers, one holding its lock with no socket ended first", { skip }, async () => {
  await helperCase("held");
});

const lsof = spawnSync("lsof", ["-v"], { stdio: "ignore" }).error === undefined;
test("one from before holding an empty lock is found by lsof and ended", { skip: skip || (lsof ? false : "no lsof here") }, async () => {
  await helperCase("held-empty");
});
