// A station out of file descriptors (D80): `spawn` fails with EMFILE / ENFILE, its ChildProcess without a pid or any of
// its streams, its error told on the next tick. What touched a stream before hearing that error threw a TypeError, and
// the error, told to none, ended the station's process (`uncaughtException`, twice in 75 s on a Mac). Run for real in a
// process of its own (test/workers/spawn-emfile-child.ts: MbProcess, runRepoGit, runGit, SessionsProgram, the vault's
// runWith and capture) whose descriptors are limited and all taken: this one's
// stay whole for the tests beside it.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

const child = fileURLToPath(new URL("./workers/spawn-emfile-child.ts", import.meta.url));

test("a spawn failing with EMFILE is told as an error and an end, never thrown nor left to end the station", { skip: process.platform === "win32" ? "no ulimit on Windows" : false }, () => {
  const run = spawnSync("/bin/sh", ["-c", 'ulimit -n 256 && exec "$0" "$@"', process.execPath, child], { encoding: "utf8", timeout: 120_000 });
  assert.equal(run.status, 0, `the child failed: ${run.stderr}`);
  const line = run.stdout.split("\n").reverse().find((l) => l.startsWith('{"mbProcess"'));
  assert.ok(line, `no result from the child: ${run.stdout}\n${run.stderr}`);
  const said = JSON.parse(line);

  assert.deepEqual(said.uncaught, []);
  assert.deepEqual(said.mbProcess, { emfile: true, threw: null, errors: ["EMFILE"], exited: -24, live: 0 });
  assert.equal(said.runRepoGitSpared, true);
  assert.deepEqual(said.runRepoGit, { emfile: true, threw: null, answer: { ok: false, stdout: "" } });
  assert.deepEqual(said.runGit, { emfile: true, threw: null, ok: false, said: true });
  assert.deepEqual(said.sessionsProgram, { emfile: true, threw: null, started: true, exited: -24, ended: true });
  assert.deepEqual(said.vaultRun, { emfile: true, threw: null, code: null, said: true });
  assert.deepEqual(said.vaultCapture, { emfile: true, threw: null, code: null, out: "", said: true });
});
