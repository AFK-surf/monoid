// `main.js run` with no launcher (a checkout, a script) took no lock of the data directory, and its loopback port fell
// back to a free one where the launcher's was taken: a second whole station started beside the one running there, both
// on its key (2026-11-16). Now it is refused as the launcher refuses a second (native/launcher main.rs `HELD`, 3).
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

const main = fileURLToPath(new URL("../src/main.ts", import.meta.url));
/// A pid no process has (past every system's highest).
const GONE = 99_999_999;

function dataDir(t: { after(f: () => unknown): void }) {
  const data = mkdtempSync(join(tmpdir(), "run-held-"));
  mkdirSync(join(data, "run"));
  writeFileSync(join(data, "config.json"), JSON.stringify({ language: "en" }));
  t.after(() => rmSync(data, { recursive: true, force: true }));
  return data;
}

const run = (data: string, more: string[] = []) =>
  spawnSync(process.execPath, [main, "run", "--app", join(data, "app"), "--data", data, ...more], { env: { ...process.env, STILLFAIL_CONFIG: join(data, "config.json") }, encoding: "utf8", timeout: 120_000 });

test("run with no launcher on a data directory a launcher runs is refused with the launcher's exit", (t) => {
  const data = dataDir(t);
  // The launcher's pid as station.json names it: a process that is there (this test's).
  writeFileSync(join(data, "run", "station.json"), JSON.stringify({ pid: process.pid, version: "0.1.2", handoff: 1 }));
  const second = run(data);
  assert.equal(second.status, 3, second.stderr);
  assert.match(second.stderr, /Another still\.fail station is running on this data directory/);
  assert.ok(second.stderr.includes(data));
});

test("run with no launcher where another such process holds the sessions is refused", async (t) => {
  const data = dataDir(t);
  // Another process, there while the test runs: hub.json names it.
  const other = spawn(process.execPath, ["-e", "setInterval(() => {}, 1 << 30)"], { stdio: "ignore" });
  t.after(() => other.kill("SIGKILL"));
  writeFileSync(join(data, "run", "hub.json"), JSON.stringify({ pid: other.pid }));
  const second = run(data);
  assert.equal(second.status, 3, second.stderr);
  assert.match(second.stderr, /Another still\.fail station is running/);
});

test("what a station gone left (its pid no process's), and this process's own, are no other station", async (t) => {
  const { heldBy } = await import("../src/ops/held.ts");
  const data = dataDir(t);
  writeFileSync(join(data, "run", "station.json"), JSON.stringify({ pid: GONE }));
  writeFileSync(join(data, "run", "hub.json"), JSON.stringify({ pid: GONE }));
  assert.equal(heldBy(data), null);
  // Its own pid (a Node the launcher started again, its hub.json from before it) is no other.
  writeFileSync(join(data, "run", "hub.json"), JSON.stringify({ pid: process.pid }));
  assert.equal(heldBy(data), null);
  writeFileSync(join(data, "run", "station.json"), JSON.stringify({ pid: 4242 }));
  assert.equal(heldBy(data, process.pid, (pid) => pid === 4242), 4242);
  assert.equal(heldBy(data, process.pid, () => false), null);
});
