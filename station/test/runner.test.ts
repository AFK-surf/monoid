// Agents under runners (src/agents/runner.ts) with the real runner binary (STILLFAIL_RUNNER or native/runner's build):
// lines in order, taken up again after a detach exactly where acknowledged, stdin, the exit after all output.
import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import { test } from "node:test";
import { ackedOffset, endRunner, findRunner, outFile } from "../src/agents/process.ts";
import { RunnerConnection, liveRunners, runnersDir, startRunner } from "../src/agents/runner.ts";
import { platform } from "../src/platform/index.ts";
import { existingRunners } from "./runners-kept.ts";
import { tempDir } from "./temp-dir.ts";

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
/// Looks every 20 ms until `f` holds (no deadline: it happens, whatever the machine's speed, or the test hangs).
const until = async (f: () => boolean) => {
  while (!f()) await sleep(20);
};

test("an old runner can stay silent or close its socket before it reports an offset", async (t) => {
  const dir = tempDir(join(tmpdir(), "old-runner-"));
  const path = process.platform === "win32" ? `\\\\.\\pipe\\${basename(dir)}` : join(dir, "s");
  const out = join(dir, "out");
  writeFileSync(out, "abc");
  const info = { id: "old", runner: 0, pid: 0, pgid: 0, startedAt: 0, program: "", args: [], socket: path };
  let closeOnAttach = false;
  const attached = Promise.withResolvers<void>();
  const server = createServer((socket) => socket.once("data", () => {
    attached.resolve();
    if (closeOnAttach) socket.end();
  }));
  await new Promise<void>((resolve) => server.listen(path, resolve));
  t.after(() => { server.close(); });

  const first = Promise.withResolvers<() => void>();
  const second = Promise.withResolvers<() => void>();
  const quiet = ackedOffset(info, out, { after(ms, fire) {
    (ms === 400 ? first : second).resolve(fire);
    return () => {};
  } });
  await attached.promise;
  (await first.promise)();
  (await second.promise)();
  assert.deepEqual(await quiet, { at: 3, keep: null });

  closeOnAttach = true;
  assert.deepEqual(await ackedOffset(info, out, { after: () => () => {} }), { at: 3, keep: null });
});

// On Windows: runner-windows.test.ts (no fifos, no sh).
test("lines in order; a station that lets go and comes back reads on where it acknowledged", { skip: process.platform === "win32" && "runner-windows.test.ts" }, async () => {
  const data = mkdtempSync(join(tmpdir(), "runner-test-"));
  // Says two lines; once let go (the fifo written), four more and marks them said; then echoes what it is sent, then
  // exits 3.
  const go = join(data, "go");
  const said = join(data, "said");
  execFileSync("/usr/bin/mkfifo", [go]);
  const script = `echo line1; echo line2; read g < '${go}'; for i in 3 4 5 6; do echo line$i; done; : > '${said}'; read x; echo got:$x; echo oops >&2; exit 3`;
  const info = await startRunner(data, "t1", "/bin/sh", ["-c", script], process.env, data);
  assert.equal(info.id, "t1");

  const first: string[] = [];
  const a = new RunnerConnection(info, (stream, text) => void (stream === "out" && first.push(text)));
  await until(() => first.length === 2);
  await a.detach();

  // Lines come meanwhile, with nobody to read them.
  writeFileSync(go, "go\n");
  await until(() => existsSync(said));
  assert.equal(existingRunners(data).length, 1, "the runner outlives the connection");
  // As the watches read them, off the thread; and as a session finds its own, by its file alone.
  assert.deepEqual(await liveRunners(data), existingRunners(data));
  assert.equal((await findRunner(data, "t1"))?.runner, info.runner);
  assert.equal((await findRunner(data, "t2")), undefined);
  const second: string[] = [];
  const b = new RunnerConnection(info, (stream, text) => void second.push(`${stream}:${text}`));
  await until(() => second.includes("out:line6"));
  b.write("hello\n");
  const exit = await b.exited;
  assert.deepEqual(exit, { code: 3, signal: null });
  const all = [...first, ...second.filter((l) => l.startsWith("out:")).map((l) => l.slice(4))];
  assert.deepEqual(all, ["line1", "line2", "line3", "line4", "line5", "line6", "got:hello"], "no line twice, none lost");
  assert.ok(second.includes("err:oops"));
  b.done();
  // Done: the runner is gone.
  await until(() => existingRunners(data).length === 0);
  assert.deepEqual(await liveRunners(data), []);
});

test("a line of many of the runner's pieces comes whole, where it is, and is acknowledged", { skip: process.platform === "win32" && "runner-windows.test.ts" }, async () => {
  const data = mkdtempSync(join(tmpdir(), "runner-test-"));
  // A line of 1 MB (sixteen of the runner's 64 KB pieces), one after it, then it waits on its stdin.
  const long = 1 << 20;
  const script = `head -c ${long} /dev/zero | tr '\\0' x; echo; echo after; read x; exit 0`;
  const info = await startRunner(data, "t3", "/bin/sh", ["-c", script], process.env, data);
  const got: [string, number, number][] = [];
  const a = new RunnerConnection(info, (stream, text, from, to) => void (stream === "out" && got.push([text, from, to])));
  await until(() => got.length === 2);
  await a.detach();
  assert.deepEqual(got, [["x".repeat(long), 0, long + 1], ["after", long + 1, long + 7]]);
  // Both acknowledged: the runner sends a next station nothing of them.
  assert.equal((await ackedOffset(info, outFile(data, "t3"))).at, long + 7);
  const again: string[] = [];
  const b = new RunnerConnection(info, (stream, text) => void again.push(`${stream}:${text}`));
  // Once attached (the attach is sent as it connects), its stdin closed: it exits.
  await new Promise((resolve) => (b as unknown as { socket: import("node:net").Socket }).socket.once("connect", resolve));
  b.closeStdin();
  assert.deepEqual(await b.exited, { code: 0, signal: null });
  assert.deepEqual(again, []);
  b.done();
  await until(() => existingRunners(data).length === 0);
});

test("a long line given a piece at a time is joined once: what it copies is its own size, not its square", async (t) => {
  const data = mkdtempSync(join(tmpdir(), "runner-test-"));
  const got: [number, number, number][] = [];
  const line = (_: "out" | "err", text: string, from: number, to: number) => void got.push([text.length, from, to]);
  // No runner behind it: the pieces are given as a runner's messages would give them.
  const conn = new RunnerConnection({ id: "none", runner: 0, pid: 0, pgid: 0, startedAt: 0, program: "", args: [], socket: join(data, "no-such.sock") }, line);
  (conn as unknown as { socket: import("node:net").Socket }).socket.on("error", () => {});
  const give = (at: number, bytes: Buffer) => (conn as unknown as { data(s: "out", at: number, b: Buffer, l: typeof line): void }).data("out", at, bytes, line);
  const real = Buffer.concat;
  let copied = 0;
  Buffer.concat = ((list: readonly Uint8Array[], length?: number) => {
    const joined = real(list, length);
    copied += joined.length;
    return joined;
  }) as typeof Buffer.concat;
  try {
    const long = 8 << 20;
    const bytes = Buffer.alloc(long + 4, "x".charCodeAt(0));
    bytes[long] = 10;
    bytes[long + 3] = 10;
    const piece = 64 * 1024;
    for (let i = 0; i < bytes.length; i += piece) give(100 + i, bytes.subarray(i, i + piece));
    await (conn as unknown as { queue: Promise<void> }).queue;
    Buffer.concat = real;
    assert.deepEqual(got, [[long, 100, 100 + long + 1], [2, 100 + long + 1, 100 + long + 4]]);
    t.diagnostic(`copied ${copied} bytes for a line of ${long}`);
    assert.ok(copied <= 2 * long, `copied ${copied} bytes for a line of ${long}`);
  } finally {
    Buffer.concat = real;
    conn.detach();
  }
});

test("endRunner waits for a dying runner whose socket is already unlinked, and skips a stale reused pid", { skip: process.platform === "win32" && "runner-windows.test.ts" }, async () => {
  const data = tempDir(join(tmpdir(), "end-runner-"));
  const dir = runnersDir(data);
  mkdirSync(dir, { recursive: true });

  // 1. Live process whose `.sock` is already gone (simulating `finish()` mid-teardown): `endRunner` stays waiting until
  // the test kills it, then returns `false` once the process has exited.
  const dying = spawn(process.execPath, ["-e", "setInterval(() => {}, 60_000)"], { stdio: "ignore" });
  const dyingExited = new Promise<void>((resolve) => dying.once("exit", () => resolve()));
  try {
    assert.ok(dying.pid !== undefined);
    writeFileSync(join(dir, "dying.json"), JSON.stringify({
      id: "dying",
      runner: dying.pid,
      pid: dying.pid,
      pgid: dying.pid,
      startedAt: Date.now(),
      program: process.execPath,
      args: [],
      socket: join(dir, "dying.sock"),
    }));
    const waiting = endRunner(data, "dying", "test-dying");
    assert.equal(await Promise.race([waiting.then(() => "done"), sleep(80).then(() => "pending")]), "pending", "still waiting while the dying runner is alive");
    dying.kill("SIGKILL");
    assert.equal(await waiting, false, "already-exiting runner was not force-ended");
    assert.throws(() => process.kill(dying.pid!, 0), "endRunner waited until the dying runner exited");
  } finally {
    try { dying.kill("SIGKILL"); } catch {}
    await dyingExited;
  }

  // 2. Stale `.json` whose pid was reused by an unrelated process started much later: `endRunner` returns immediately.
  if ((await platform.startTimeOf(process.pid).catch(() => null)) !== null) {
    writeFileSync(join(dir, "reused.json"), JSON.stringify({
      id: "reused",
      runner: process.pid,
      pid: process.pid,
      pgid: process.pid,
      startedAt: 1,
      program: process.execPath,
      args: [],
      socket: join(dir, "reused.sock"),
    }));
    const before = performance.now();
    assert.equal(await endRunner(data, "reused", "test-reused"), false);
    assert.ok(performance.now() - before < 1000, "did not wait on a reused pid");
  }
});
