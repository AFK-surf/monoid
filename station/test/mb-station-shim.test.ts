// End-to-end tests for `stillfail-reader`'s lightweight `station_shim`:
// verifies that retired whole-station commands (`run`, `status`, `id`, `admin`, `--app`, hooks/bridges)
// hand off to Node via `execv` on Unix (preserving PID and inherited fds) and fail loudly on missing Node/scripts.
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { chmodSync, copyFileSync, mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test, type TestContext } from "node:test";
import { mbReaderBinary } from "../src/read/mb-reader.ts";

const reader = mbReaderBinary();
const skip = reader === null ? "stillfail-reader is not built here" : process.platform === "win32" ? "Unix execv PID test" : false;

const reportScript = (who: string) => `
process.stdout.write(JSON.stringify({
  who: ${JSON.stringify(who)},
  pid: process.pid,
  argv: process.argv.slice(2),
}) + "\\n");
process.exit(Number(process.env.FAKE_EXIT ?? "0"));
`;

function makeApp(t: TestContext, opts: { mainJs?: boolean; adminJs?: boolean; adminTs?: boolean; bundledNode?: boolean } = {}) {
  const base = mkdtempSync(join(tmpdir(), "sf-shim-"));
  t.after(() => rmSync(base, { recursive: true, force: true }));
  const app = join(base, "app");
  mkdirSync(join(app, "station"), { recursive: true });
  const bin = join(app, "station", "stillfail-reader");
  copyFileSync(reader!, bin);
  chmodSync(bin, 0o755);
  if (opts.mainJs) writeFileSync(join(app, "station", "main.js"), reportScript("main.js"));
  if (opts.adminJs) writeFileSync(join(app, "station", "admin-cli.js"), reportScript("admin-cli.js"));
  if (opts.adminTs) {
    mkdirSync(join(app, "bin"), { recursive: true });
    writeFileSync(join(app, "bin", "admin-cli.ts"), `const x: string = "ts"; void x;\n${reportScript("admin-cli.ts")}`);
  }
  if (opts.bundledNode) {
    mkdirSync(join(app, "node", "bin"), { recursive: true });
    symlinkSync(process.execPath, join(app, "node", "bin", "node"));
  }
  return { base, app, bin };
}

function runWithPid(file: string, args: string[], env: Record<string, string>): Promise<{ pid: number; code: number | null; stdout: string; stderr: string }> {
  return new Promise((resolve, reject) => {
    const child = spawn(file, args, { env, stdio: ["ignore", "pipe", "pipe"] });
    const pid = child.pid!;
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (d) => (stdout += d));
    child.stderr.on("data", (d) => (stderr += d));
    child.on("error", reject);
    child.on("close", (code) => resolve({ pid, code, stdout, stderr }));
  });
}

test("station_shim execs Node main.js in place (same PID) for whole-station commands and --app flag", { skip }, async (t) => {
  const { app, bin } = makeApp(t, { mainJs: true, bundledNode: true });
  const r = await runWithPid(bin, ["status", "--data", "/tmp/d1"], { PATH: "", FAKE_EXIT: "7" });
  assert.equal(r.code, 7, r.stderr);
  const out = JSON.parse(r.stdout.trim());
  assert.equal(out.who, "main.js");
  assert.equal(out.pid, r.pid, "must execv in place preserving PID");
  assert.deepEqual(out.argv, ["status", "--data", "/tmp/d1"]);
  assert.match(r.stderr, /"engine": "moonbit" is retired/);

  // No subcommand, but --app passed (older launcher style)
  const r2 = await runWithPid(bin, ["--app", app, "--port", "4760"], { PATH: "" });
  assert.equal(r2.code, 0, r2.stderr);
  const out2 = JSON.parse(r2.stdout.trim());
  assert.equal(out2.who, "main.js");
  assert.equal(out2.pid, r2.pid);
  assert.deepEqual(out2.argv, ["--app", app, "--port", "4760"]);
});

test("station_shim hands off admin to station/admin-cli.js (or dev bin/admin-cli.ts) stripping 'admin'", { skip }, async (t) => {
  const rel = makeApp(t, { adminJs: true, bundledNode: true });
  const r1 = await runWithPid(rel.bin, ["admin", "--data", "/tmp/d2", "whoami", "--json"], { PATH: "" });
  assert.equal(r1.code, 0, r1.stderr);
  const out1 = JSON.parse(r1.stdout.trim());
  assert.equal(out1.who, "admin-cli.js");
  assert.equal(out1.pid, r1.pid);
  assert.deepEqual(out1.argv, ["--data", "/tmp/d2", "whoami", "--json"]);

  const dev = makeApp(t, { adminTs: true, bundledNode: true });
  const r2 = await runWithPid(dev.bin, ["admin", "users", "list"], { PATH: "" });
  assert.equal(r2.code, 0, r2.stderr);
  const out2 = JSON.parse(r2.stdout.trim());
  assert.equal(out2.who, "admin-cli.ts");
  assert.equal(out2.pid, r2.pid);
  assert.deepEqual(out2.argv, ["users", "list"]);
});

test("station_shim runs .mjs/.js hook scripts via Node directly and respects STILLFAIL_NODE > app/node > PATH", { skip }, async (t) => {
  const { base, bin } = makeApp(t, { mainJs: true });
  const hook = join(base, "repo-rules-hook.mjs");
  writeFileSync(hook, reportScript("hook.mjs"));

  // Found via STILLFAIL_NODE
  const r1 = await runWithPid(bin, [hook, "arg1", "arg2"], { PATH: "", STILLFAIL_NODE: process.execPath });
  assert.equal(r1.code, 0, r1.stderr);
  const out1 = JSON.parse(r1.stdout.trim());
  assert.equal(out1.who, "hook.mjs");
  assert.equal(out1.pid, r1.pid);
  assert.deepEqual(out1.argv, ["arg1", "arg2"]);

  // Found via PATH when STILLFAIL_NODE is unset and no bundled node
  const pathDir = join(base, "pathbin");
  mkdirSync(pathDir);
  symlinkSync(process.execPath, join(pathDir, "node"));
  const r2 = await runWithPid(bin, [hook, "via-path"], { PATH: pathDir });
  assert.equal(r2.code, 0, r2.stderr);
  assert.deepEqual(JSON.parse(r2.stdout.trim()).argv, ["via-path"]);
});

test("station_shim fails loudly with non-zero exit when Node or entry script is missing", { skip }, (t) => {
  const noNode = makeApp(t, { mainJs: true });
  const r1 = spawnSync(noNode.bin, ["status"], { env: { PATH: "" }, encoding: "utf8" });
  assert.notEqual(r1.status, 0);
  assert.match(r1.stderr, /no Node executable was found/);

  const noScript = makeApp(t, { bundledNode: true });
  const r2 = spawnSync(noScript.bin, ["run", "--app", noScript.app], { env: { PATH: "" }, encoding: "utf8" });
  assert.notEqual(r2.status, 0);
  assert.match(r2.stderr, /station\/main\.js was not found/);
});
