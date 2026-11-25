// `pnpm test`: the cloud's tests, with the Workers bundled once for all of them (test/bundles.ts) rather than by
// each file's process. Arguments go to `node --test`; any not starting with "-" are the files to run instead of all.
// The tests stay on tsx: the sources import each other without extensions (some 250 imports), which Node's own
// TypeScript does not resolve. This file and test/bundles.ts import none, so Node runs them itself.
import { spawn } from "node:child_process";
import { accessSync, constants, mkdirSync, mkdtempSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { BUNDLES_ENV, writeBundles } from "./bundles.ts";

const args = process.argv.slice(2);
const named = args.filter((a) => !a.startsWith("-"));
// Each file by name, never a glob: a process naming one test file is taken for that file's by scripts/check.sh
// (`open_tests`), which signals it to say what hung.
const files = named.length > 0 ? named : readdirSync("test").filter((f) => f.endsWith(".test.ts")).sort().map((f) => `test/${f}`);

// Each harness's Miniflare keeps its Durable Objects' SQLite in a directory of its own under the temporary directory,
// and SQLite syncs every write it commits: on a Linux disk (CI's, a btrfs one) that was half of a test's time
// (revoked-events.test.ts: 25 s, 12 s on tmpfs). On Linux the run's temporary directory is in memory, where a sync
// costs nothing; what is written and read is the same. (A Mac's sync does not wait for the disk.)
const memory = (() => {
  if (process.platform !== "linux") return null;
  try {
    accessSync("/dev/shm", constants.W_OK);
    return "/dev/shm";
  } catch {
    return null;
  }
})();
const dir = mkdtempSync(join(memory ?? tmpdir(), "stillfail-cloud-tests-"));
const bundles = join(dir, "bundles"), temporary = join(dir, "tmp");
let code = 1;
try {
  mkdirSync(bundles);
  mkdirSync(temporary);
  await writeBundles(bundles);
  const child = spawn(process.execPath, ["--import", "tsx", "--test", "--test-timeout=60000", ...args.filter((a) => a.startsWith("-")), ...files], {
    stdio: "inherit",
    env: { ...process.env, [BUNDLES_ENV]: bundles, ...(memory ? { TMPDIR: temporary } : {}) },
  });
  // ^C and a runner's stop reach the tests too (one process group); this waits for them to end before cleaning up.
  for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"] as const) process.on(signal, () => child.kill(signal));
  code = await new Promise<number>((resolve) => child.on("exit", (exit, signal) => resolve(exit ?? (signal ? 128 : 1))));
} finally {
  rmSync(dir, { recursive: true, force: true });
}
process.exit(code);
