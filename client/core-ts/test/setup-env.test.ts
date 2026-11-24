// test/setup-env.mjs: a test file asked SIGUSR2 (scripts/check.sh, stopped at CI's time) says the test it runs, to
// $STILLFAIL_TEST_HUNG/<pid>, and Node writes no diagnostic report of its own. A test file of its own in a process of
// its own, as the runner gives each: it says each step on its output and ends as its input does. Nothing here waits on
// time: each step waits for the line the file says next, and the file ending first fails it.
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";

const SETUP = fileURLToPath(new URL("./setup-env.mjs", import.meta.url));

// Its own listener comes after setup-env's (loaded by --import before it), so "answered" is said once the report is
// written.
const FIXTURE = `import { test } from "node:test";
process.on("SIGUSR2", () => process.stdout.write("answered\\n"));
test("waits for its input to end", async () => {
  process.stdout.write(\`running, a report on the signal: \${process.report.reportOnSignal}\\n\`);
  process.stdin.resume();
  await new Promise((done) => process.stdin.on("end", done));
});
`;

test("a test file asked SIGUSR2 names the test it runs", { skip: process.platform === "win32" && "no SIGUSR2 on Windows" }, async () => {
  const dir = mkdtempSync(join(tmpdir(), "core-hung-"));
  const hung = join(dir, "hung");
  const reports = join(dir, "reports");
  mkdirSync(hung);
  mkdirSync(reports);
  const file = join(dir, "hang.test.mjs");
  writeFileSync(file, FIXTURE);
  // --report-on-signal: what setup-env turns off, on, so that a report would be written were it not.
  const child = spawn(process.execPath, ["--report-on-signal", `--report-directory=${reports}`, "--import", SETUP, file], {
    cwd: dir,
    // (Not the runner's child: run alone, it reports as a file run by hand, on its output.)
    env: { ...Object.fromEntries(Object.entries(process.env).filter(([k]) => k !== "NODE_TEST_CONTEXT")), STILLFAIL_TEST_HUNG: hung },
    stdio: ["pipe", "pipe", "inherit"],
  });
  const exited = once(child, "exit");
  const lines = createInterface({ input: child.stdout })[Symbol.asyncIterator]();
  const next = async () => {
    const line = await lines.next();
    assert.ok(!line.done, "the test file ended before saying its next step");
    return line.value;
  };
  try {
    // Were Node's report on, it would take the signal and no listener would hear it: said before it is sent.
    assert.equal(await next(), "running, a report on the signal: false");
    assert.ok(child.kill("SIGUSR2"));
    assert.equal(await next(), "answered");
    const report = readFileSync(join(hung, String(child.pid)), "utf8");
    assert.match(report, /hang\.test\.mjs\n/);
    assert.match(report, /\n {2}test "waits for its input to end" running \d+ s\n/);
    assert.match(report, /\n {4}resources: \S/);
    assert.deepEqual(readdirSync(reports), []);
    child.stdin.end();
    assert.deepEqual(await exited, [0, null]);
  } finally {
    if (child.exitCode === null && child.signalCode === null) {
      child.kill("SIGKILL");
      await exited;
    }
    rmSync(dir, { recursive: true, force: true });
  }
});
