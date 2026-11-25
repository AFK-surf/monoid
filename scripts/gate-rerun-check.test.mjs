// scripts/gate-rerun-check.mjs on the attempts of runs as GitHub's API gives them, read from a directory of the test's.
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { check } from "./gate-rerun-check.mjs";

const T0 = Date.parse("2026-11-17T08:00:00Z");
const at = (s) => new Date(T0 + s * 1000).toISOString();
const step = (name, conclusion = "success") => ({ name, conclusion });
const setup = [step("Set up job"), step("Run actions/checkout@v5"), step("Run ./.github/actions/setup-linux")];
function job(id, name, { took = 90, conclusion = "failure", runner = "GitHub Actions 1", steps = [] } = {}) {
  return { id, name, conclusion, runner_name: runner, started_at: at(0), completed_at: at(took), steps };
}

/** Runs the check on attempts [{ run, jobs }, …], the last attempt being this one; logs by job id. */
async function run(attempts, logs = {}) {
  const dir = mkdtempSync(join(tmpdir(), "gate-rerun-"));
  mkdirSync(join(dir, "logs"));
  attempts.forEach((a, i) => writeFileSync(join(dir, `attempt-${i + 1}.json`), JSON.stringify(a)));
  for (const [id, text] of Object.entries(logs)) writeFileSync(join(dir, "logs", `${id}.txt`), text);
  const said = [];
  const ok = await check({ GITHUB_RUN_ATTEMPT: String(attempts.length + 1), GATE_RERUN_FIXTURE_DIR: dir }, { log: (l) => said.push(l) });
  return { ok, said: said.join("\n") };
}
const passed = (name) => job(1, name, { conclusion: "success", steps: [...setup, step("Full check")] });
const gateFailed = job(99, "gate", { took: 5, steps: [step("Set up job"), step("Run echo", "failure")] });

test("the first attempt goes through, nothing read", async () => {
  assert.equal(await check({ GITHUB_RUN_ATTEMPT: "1", GATE_RERUN_FIXTURE_DIR: "/nonexistent" }, { log() {} }), true);
  assert.equal(await check({ GATE_RERUN_FIXTURE_DIR: "/nonexistent" }, { log() {} }), true);
});

test("after the checkout failed: let through", async () => {
  const r = await run([{ run: { conclusion: "failure" }, jobs: [passed("check"), gateFailed, job(2, "check-linux", { took: 40, steps: [step("Set up job"), step("Run actions/checkout@v5", "failure"), step("Full check (ts)", "skipped")] })] }]);
  assert.equal(r.ok, true, r.said);
  assert.match(r.said, /check-linux: let through: only its setting up failed \(Run actions\/checkout@v5\)/);
});

test("after a run cancelled whole, a job no runner took among it: let through", async () => {
  const r = await run([{
    run: { conclusion: "cancelled" },
    jobs: [
      job(2, "check-mac", { conclusion: "cancelled", runner: null, took: 0, steps: [] }),
      job(3, "check-station (0)", { conclusion: "cancelled", took: 130, steps: [...setup, step("Station tests", "cancelled")] }),
      gateFailed,
    ],
  }]);
  assert.equal(r.ok, true, r.said);
  assert.match(r.said, /check-mac: let through: no runner took it/);
  assert.match(r.said, /check-station \(0\): let through: cancelled with its run after 130 s/);
});

test("after Full check (ts) failed: not let through, the attempt, the job and the step said", async () => {
  const r = await run(
    [{ run: { conclusion: "failure" }, jobs: [passed("check"), job(4, "check-linux", { took: 150, steps: [...setup, step("Full check (ts)", "failure")] }), gateFailed] }],
    { 4: "2026-11-17T08:01:00.0000000Z · tests: web … FAILED (40 s)\n2026-11-17T08:01:00.0000000Z ✖ the chat list keeps its order\n##[error]Process completed with exit code 1.\n" },
  );
  assert.equal(r.ok, false);
  assert.match(r.said, /attempt 1: check-linux: Full check \(ts\) failed: · tests: web … FAILED/);
  assert.match(r.said, /never rerun green/);
});

test("after a job ran its time out, cut or cancelled at 295 s: not let through", async () => {
  for (const [name, conclusion] of [["app build", "cancelled"], ["check-station (2)", "failure"], ["check", "timed_out"]]) {
    const r = await run([{ run: { conclusion: conclusion === "cancelled" ? "cancelled" : "failure" }, jobs: [job(5, name, { took: 295, conclusion, steps: [...setup, step("Build", "cancelled")] }), gateFailed] }]);
    assert.equal(r.ok, false, name);
    assert.match(r.said, new RegExp(`${name.replace(/[()]/g, "\\$&")}: NOT let through: ran its time out \\(295 s\\)`));
  }
});

test("after a step failed on github.com's 504: let through; with a limit reached or a test failed in its log beside it: not", async () => {
  const jobs = [job(6, "check-core (1)", { took: 70, steps: [...setup, step("Core tests", "failure")] }), gateFailed];
  const ok = await run([{ run: { conclusion: "failure" }, jobs }], { 6: "fetching https://github.com/AFK-surf/monoid/releases/download/native-artifacts/x.zst\ncurl: (22) The requested URL returned error: 504 Gateway Time-out\n##[error]Process completed with exit code 22.\n" });
  assert.equal(ok.ok, true, ok.said);
  assert.match(ok.said, /check-core \(1\): let through: Core tests failed for GitHub's or the network's sake: .*504 Gateway Time-out/);
  const reset = await run([{ run: { conclusion: "failure" }, jobs }], { 6: "Error: connect ETIMEDOUT 140.82.112.4:443 (github.com)\n" });
  assert.equal(reset.ok, true, reset.said);
  const node = await run([{ run: { conclusion: "failure" }, jobs }], { 6: "read ECONNRESET from nodejs.org\n" });
  assert.equal(node.ok, true, node.said);
  for (const also of ["scripts/with-timeout.sh: not done after 245 s\n", "exit code 124\n", "[stillfail] test foo failed\n", "AssertionError [ERR_ASSERTION]: 1 !== 2\n", "test/x.test.ts: left running after its tests (ended now):\n"]) {
    const r = await run([{ run: { conclusion: "failure" }, jobs }], { 6: `504 Gateway Time-out\n${also}` });
    assert.equal(r.ok, false, also);
  }
});

test("after a step failed and its log says nothing of GitHub's, or is gone: not let through", async () => {
  const jobs = [job(7, "bundle", { took: 60, steps: [...setup, step("Bundle", "failure")] }), gateFailed];
  assert.equal((await run([{ run: { conclusion: "failure" }, jobs }], { 7: "something else went wrong\n" })).ok, false);
  const gone = await run([{ run: { conclusion: "failure" }, jobs }]);
  assert.equal(gone.ok, false);
  assert.match(gone.said, /its log cannot be read/);
});

test("the runner shut down under a job before its time: let through; every attempt before is judged", async () => {
  const shut = { run: { conclusion: "failure" }, jobs: [job(8, "natives", { took: 100, steps: [...setup, step("Get or build the native parts", "failure")] })] };
  const logs = { 8: "##[error]The runner has received a shutdown signal. This can happen when the runner service is stopped.\n", 9: "· tests: station 2/6 … FAILED (12 s)\n" };
  assert.equal((await run([shut], logs)).ok, true);
  const second = { run: { conclusion: "failure" }, jobs: [job(9, "check-station (2)", { took: 100, steps: [...setup, step("Station tests", "failure")] })] };
  const r = await run([shut, second], logs);
  assert.equal(r.ok, false);
  assert.match(r.said, /attempt 2: check-station \(2\): NOT let through/);
});

test("a 504 under scripts/check.sh's own FAILED line: let through; beside what is the change's for certain: not", async () => {
  const jobs = [job(10, "check-linux", { took: 80, steps: [...setup, step("Full check (ts)", "failure")] }), gateFailed];
  const curl = "curl: (22) The requested URL returned error: 504 Gateway Time-out\n";
  const summary = "· Full check … FAILED (12 s)\n";
  const ok = await run([{ run: { conclusion: "failure" }, jobs }], { 10: curl + summary });
  assert.equal(ok.ok, true, ok.said);
  assert.match(ok.said, /check-linux: let through: .*504 Gateway Time-out/);
  for (const also of ["AssertionError: expected 1\n", "##[error]Process completed with exit code 124.\n", "[stillfail] test foo failed\n"]) {
    const r = await run([{ run: { conclusion: "failure" }, jobs }], { 10: curl + also + summary });
    assert.equal(r.ok, false, also);
    assert.match(r.said, /check-linux: NOT let through/);
  }
  // (a check's FAILED with nothing of GitHub's beside it stays the change's)
  assert.equal((await run([{ run: { conclusion: "failure" }, jobs }], { 10: summary })).ok, false);
});

test("a step of the natives action failing is the job's setting up", async () => {
  const r = await run([{ run: { conclusion: "failure" }, jobs: [job(11, "check-core (0)", { took: 30, steps: [...setup, step("Run ./.github/actions/natives", "failure"), step("Core tests", "skipped")] }), gateFailed] }]);
  assert.equal(r.ok, true, r.said);
});

test("cut at 5 minutes after its checkout's SYN to github.com was lost: let through; with the change's own failure or no network's in its log: not", async () => {
  const steps = [
    { name: "Set up job", conclusion: "success", started_at: at(0), completed_at: at(2) },
    { name: "Run actions/checkout@v5", conclusion: "success", started_at: at(2), completed_at: at(231) },
    { name: "Station tests", conclusion: "cancelled", started_at: at(245), completed_at: at(306) },
  ];
  const jobs = [job(12, "check-station (1)", { took: 309, conclusion: "cancelled", steps }), gateFailed];
  const syn = "fatal: unable to access 'https://github.com/AFK-surf/monoid/': Failed to connect to github.com port 443 after 135088 ms: Couldn't connect to server\n";
  const cut = "##[error]The job has exceeded the maximum execution time of 5m0s\n";
  const ok = await run([{ run: { conclusion: "failure" }, jobs }], { 12: syn + cut });
  assert.equal(ok.ok, true, ok.said);
  assert.match(ok.said, /check-station \(1\): let through: setting up took 231 s \(.*Failed to connect to github\.com port 443.*\), leaving 61 s/);
  for (const also of ["AssertionError: expected 1\n", "exit code 124\n"]) {
    const r = await run([{ run: { conclusion: "failure" }, jobs }], { 12: syn + also + cut });
    assert.equal(r.ok, false, also);
    assert.match(r.said, /check-station \(1\): NOT let through: ran its time out \(309 s\)/);
  }
  assert.equal((await run([{ run: { conclusion: "failure" }, jobs }], { 12: cut })).ok, false);
});

test("cut at 5 minutes after git fetch RPC failed (HTTP 408 / curl 16 / curl 56): let through; non-transport HTTP or hard failure: not", async () => {
  // Mirrors #8731 natives-mac-reader job 139410496631 (run 45671346689): checkout failed after 181 s on git RPC 408/curl 56,
  // zero own steps ran, and GitHub recorded completed_at 329 s after started_at (cancelled).
  const steps = [
    { name: "Set up job", conclusion: "success", started_at: at(15), completed_at: at(28) },
    { name: "Run echo \"JOB_END=...\" >> \"$GITHUB_ENV\"", conclusion: "success", started_at: at(28), completed_at: at(28) },
    { name: "Run actions/checkout@v5", conclusion: "failure", started_at: at(28), completed_at: at(209) },
    { name: "Post Run actions/checkout@v5", conclusion: "success", started_at: at(209), completed_at: at(209) },
    { name: "Complete job", conclusion: "success", started_at: at(209), completed_at: at(209) },
  ];
  const jobs = [job(13, "natives-mac-reader", { took: 329, conclusion: "cancelled", steps }), gateFailed];
  const cut = "##[error]The job has exceeded the maximum execution time of 5m0s\n";
  for (const rpc of [
    "##[error]error: RPC failed; HTTP 408 curl 22 The requested URL returned error: 408\n",
    "##[error]error: RPC failed; curl 56 Connection died, tried 5 times before giving up\n",
    "##[error]error: RPC failed; curl 16 Error in the HTTP2 framing layer\n",
    "##[error]error: RPC failed; curl 92 HTTP/2 stream 1 was not closed cleanly\n",
  ]) {
    const ok = await run([{ run: { conclusion: "failure" }, jobs }], { 13: rpc + cut });
    assert.equal(ok.ok, true, rpc + "\n" + ok.said);
    assert.match(ok.said, /natives-mac-reader: let through: setting up took 194 s \(.*RPC failed; .*\), leaving 0 s/);
    const withHard = await run([{ run: { conclusion: "failure" }, jobs }], { 13: rpc + "AssertionError: expected 1\n" + cut });
    assert.equal(withHard.ok, false, rpc);
  }
  for (const nonTransport of [
    "##[error]error: RPC failed; HTTP 403 curl 22 The requested URL returned error: 403\n",
    "##[error]error: RPC failed; HTTP 404 curl 22 The requested URL returned error: 404\n",
    "##[error]error: RPC failed; HTTP 500 curl 22 The requested URL returned error: 500\n",
  ]) {
    const denied = await run([{ run: { conclusion: "failure" }, jobs }], { 13: nonTransport + cut });
    assert.equal(denied.ok, false, nonTransport + "\n" + denied.said);
  }
});

test("retried-and-succeeded checkout RPC line does not excuse a later own-step test failure", async () => {
  const jobs = [job(14, "check-station (2)", { took: 110, steps: [...setup, step("Station tests", "failure")] }), gateFailed];
  const rpc = "##[error]error: RPC failed; curl 56 Connection died, tried 5 times before giving up\n";
  for (const soft of ["not ok 3 - some test\n", "✖ some test\n", "· tests: station 2/6 … FAILED (12 s)\n"]) {
    const r = await run([{ run: { conclusion: "failure" }, jobs }], { 14: rpc + soft });
    assert.equal(r.ok, false, soft + "\n" + r.said);
    assert.match(r.said, /check-station \(2\): NOT let through/);
  }
});

// Trimmed from #7864, windows-natives job 136520782682:
// https://github.com/AFK-surf/monoid/actions/runs/44803265194/job/136520782682
const missingPrebuild = String.raw`2026-11-20T19:34:41.3524146Z native: engine win32-x64 8a82aa4af46cae64467ef117: downloaded (2.6 MB, 0.5 s)
2026-11-20T19:34:41.3578846Z C:\Users\runneradmin\AppData\Local\stillfail-native\engine\win32-x64-8a82aa4af46cae64467ef117
2026-11-20T19:34:42.3166623Z native: shell win32-x64 bea4624b4d0bc846edb816bc is not prebuilt: run the prebuild workflow on the branch, gh workflow run prebuild.yml -R AFK-surf/monoid --ref fix/mesh-prefer-direct (or on a Mac, node scripts/native.ts prebuild shell:win32-x64)
2026-11-20T19:34:42.3754834Z ##[error]Process completed with exit code 1.
`;
const missingJobs = [job(136520782682, "windows-natives", { took: 22, steps: [...setup, step("Fetch Windows natives", "failure")] }), gateFailed];
const missingAttempt = { run: { conclusion: "failure" }, jobs: missingJobs };

test("a missing native artifact stopped the job before its work: let through", async () => {
  const r = await run([missingAttempt], { 136520782682: missingPrebuild });
  assert.equal(r.ok, true, r.said);
  assert.match(r.said, /stopped before its work: native: shell win32-x64/);
});

test("a missing prebuild does not excuse another failure, even beside a network error", async () => {
  for (const failure of ["AssertionError: expected a reply", "error[E0308]: mismatched types", "test/a.test.ts: left running after its tests", "exit code 124", "The job has exceeded the maximum execution time", "not ok 1 - a test", "✖ a test", "tests FAILED", "test foo failed", "##[error]another step failed", "Error: cannot open input"]) {
    const r = await run([missingAttempt], { 136520782682: missingPrebuild + failure + "\n504 Gateway Time-out\n" });
    assert.equal(r.ok, false, failure + "\n" + r.said);
  }
});

test("prebuilt words, partial diagnostics and inconsistent targets do not excuse failure", async () => {
  for (const log of ["prebuilt artifact was downloaded", "native: shell win32-x64 key is not prebuilt", missingPrebuild.replace("run the prebuild workflow", "check the prebuilt files"), missingPrebuild.replace("prebuild shell:win32-x64", "prebuild shell:linux-x64"), missingPrebuild.replace("native: shell", "echo native: shell")]) {
    assert.equal((await run([missingAttempt], { 136520782682: log })).ok, false, log);
  }
});

test("a missing prebuild does not excuse a second failed step or an exhausted time limit", async () => {
  for (const options of [
    { steps: [...setup, step("Fetch natives", "failure"), step("Another step", "failure")] },
    { took: 295, steps: [...setup, step("Fetch natives", "failure")] },
  ]) {
    const r = await run([{ run: { conclusion: "failure" }, jobs: [job(136520782682, "windows-natives", options)] }], { 136520782682: missingPrebuild });
    assert.equal(r.ok, false, r.said);
  }
});
