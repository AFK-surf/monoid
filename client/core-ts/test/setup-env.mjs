import { afterEach, beforeEach } from "node:test";
import { writeFileSync } from "node:fs";

// A test that hangs says where (scripts/check.sh, stopped at CI's time, sends SIGUSR2 to each test file still running):
// the tests running and since when, else what keeps the process open after its tests (a leftover process or server),
// to $STILLFAIL_TEST_HUNG/<pid> or stderr. Without this a hang said nothing but its file (45381066232, check-core:
// test/web-sql-bounds.test.ts). Only this here: every test file loads it, so it costs nothing as it loads.

const running = new Map();
beforeEach((t) => void running.set(t, Date.now()));
afterEach((t) => void running.delete(t));
// Node writes a diagnostic report on this signal in a test file's process otherwise (where --report-on-signal says).
process.report.reportOnSignal = false;
process.on("SIGUSR2", () => {
  const now = Date.now();
  const lines = [...running].map(([t, at]) => `test "${t.fullName}" running ${Math.round((now - at) / 1000)} s`);
  if (lines.length === 0) lines.push("no test running: a hook, or what its tests left open");
  for (const h of process._getActiveHandles()) {
    if (h?.constructor?.name === "ChildProcess") lines.push(`  child process ${h.pid}: ${h.spawnargs.join(" ").slice(0, 160)}`);
    else if (h?.constructor?.name === "Server" && h.address?.()) lines.push(`  server listening at ${JSON.stringify(h.address())}`);
  }
  lines.push(`  resources: ${process.getActiveResourcesInfo().join(", ")}`);
  const text = `${process.argv.find((a) => /\.test\.(ts|mjs)$/.test(a)) ?? "?"}\n${lines.map((l) => `  ${l}`).join("\n")}\n`;
  const dir = process.env.STILLFAIL_TEST_HUNG;
  if (dir) writeFileSync(`${dir}/${process.pid}`, text);
  else process.stderr.write(text);
});
