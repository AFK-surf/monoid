// Black-box contract tests for `--builder footprint` against any reader binary.
//
// By default this runs against the shipped MoonBit `stillfail-reader` (`mbReaderBinary()`).
// Set `STILLFAIL_READER_CANDIDATE=/path/to/stillfail-pion` to verify a candidate binary
// with zero edits to this suite. Never silently skips when the binary is missing.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { chmodSync, existsSync, linkSync, mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, normalize, sep } from "node:path";
import { after, test } from "node:test";
import { platform } from "../../src/platform/index.ts";
import { mbReaderBinary, Said } from "../../src/read/mb-reader.ts";
import { MEASURE_ROOM, MEASURE_UP_TO, type MeasureBudget, type Room } from "../../src/sessions/footprint.ts";
import { measureRoomReference, measuredReference, measuredUpToReference } from "../footprint-reference.ts";

function resolveCandidateBinary(): string {
  const injected = process.env.STILLFAIL_READER_CANDIDATE?.trim();
  if (injected) {
    assert.ok(existsSync(injected), `STILLFAIL_READER_CANDIDATE does not exist: ${injected}`);
    return injected;
  }
  const binary = mbReaderBinary();
  assert.ok(
    binary !== null,
    "stillfail-reader binary not found; set STILLFAIL_READER_CANDIDATE or run via `node ../scripts/native.ts run reader -- ...`",
  );
  return binary;
}

const CANDIDATE = resolveCandidateBinary();

const tempDirs: string[] = [];
after(() => {
  for (const dir of tempDirs) {
    try { chmodSync(dir, 0o755); } catch {}
    rmSync(dir, { recursive: true, force: true });
  }
});

function freshDir(prefix = "footprint-contract-"): string {
  const dir = mkdtempSync(join(tmpdir(), prefix));
  tempDirs.push(dir);
  return dir;
}

function writeSized(filePath: string, bytes: number): void {
  mkdirSync(join(filePath, ".."), { recursive: true });
  writeFileSync(filePath, Buffer.alloc(bytes, 0x41));
}

type FootprintRawResponse = {
  size?: number;
  complete?: boolean;
  reason?: string;
  rebuild?: [string, number][];
  enough?: true;
  error?: string;
  code?: string;
};

type RawInvocation = {
  pid: number;
  messages: unknown[];
  stderr: string;
  exitCode: number | null;
  signal: NodeJS.Signals | null;
};

async function invokeFootprintRaw(rawLine: string): Promise<RawInvocation> {
  return await new Promise<RawInvocation>((resolve, reject) => {
    const child = spawn(CANDIDATE, ["--builder", "footprint", "--sep", sep], {
      stdio: ["pipe", "pipe", "pipe"],
      windowsHide: true,
    });
    const pid = child.pid;
    assert.ok(typeof pid === "number" && pid > 0, "expected a real child process pid");
    const messages: unknown[] = [];
    let stderr = "";
    const said = new Said((msg) => messages.push(msg));
    child.stdout!.on("data", (chunk: Buffer) => said.push(chunk));
    child.stderr!.on("data", (chunk: Buffer) => { stderr += chunk.toString("utf8"); });
    child.stdin!.on("error", () => {});
    child.on("error", reject);
    child.on("close", (exitCode, signal) => {
      resolve({ pid, messages, stderr, exitCode, signal });
    });
    child.stdin!.end(rawLine);
  });
}

async function runFootprint(
  targetPath: string,
  ask: { finding: boolean; strict: boolean; stopAfter?: number },
  budget: MeasureBudget = MEASURE_ROOM,
): Promise<{ pid: number; response: FootprintRawResponse }> {
  const payload = {
    path: targetPath,
    base: normalize(targetPath),
    ...ask,
    maxEntries: budget.maxEntries ?? MEASURE_ROOM.maxEntries,
    maxDurationMs: Math.max(0, budget.maxDurationMs ?? MEASURE_ROOM.maxDurationMs),
  };
  const inv = await invokeFootprintRaw(`${JSON.stringify(payload)}\n`);
  assert.equal(inv.exitCode, 0, `footprint exited with ${inv.exitCode} (stderr: ${inv.stderr})`);
  assert.equal(inv.signal, null);
  assert.equal(inv.messages.length, 1, `expected exactly 1 JSON response, got ${inv.messages.length}`);
  return { pid: inv.pid, response: inv.messages[0] as FootprintRawResponse };
}

async function candidateMeasureRoom(dir: string, budget: MeasureBudget = MEASURE_ROOM): Promise<Room> {
  const { response } = await runFootprint(dir, { finding: true, strict: false }, budget);
  if (response.error !== undefined) {
    throw Object.assign(new Error(response.error), { code: response.code });
  }
  const { size, complete } = response;
  assert.ok(typeof size === "number", `expected numeric size, got ${typeof size}`);
  assert.ok(typeof complete === "boolean", `expected boolean complete, got ${typeof complete}`);
  return {
    bytes: size,
    rebuild: response.rebuild ?? [],
    complete,
    ...(response.reason !== undefined ? { reason: response.reason } : {}),
  };
}

async function candidateMeasured(dir: string, budget: MeasureBudget = MEASURE_ROOM): Promise<number> {
  const { response } = await runFootprint(dir, { finding: false, strict: false }, budget);
  if (response.error !== undefined) {
    throw Object.assign(new Error(response.error), { code: response.code });
  }
  const { size } = response;
  assert.ok(typeof size === "number", `expected numeric size, got ${typeof size}`);
  return size;
}

async function candidateMeasuredUpTo(
  dir: string,
  limit: number,
  budget: MeasureBudget = MEASURE_UP_TO,
  strict = true,
): Promise<{ bytes: number; complete: boolean; truncated?: true }> {
  const { response } = await runFootprint(dir, { finding: false, strict, stopAfter: limit }, budget);
  if (response.error !== undefined) {
    throw Object.assign(new Error(response.error), { code: response.code });
  }
  const { size } = response;
  assert.ok(typeof size === "number", `expected numeric size, got ${typeof size}`);
  if (response.enough) return { bytes: size, complete: false };
  if (response.complete) return { bytes: size, complete: true };
  return { bytes: size, complete: false, truncated: true };
}

function assertProcessGone(pid: number): void {
  let alive = true;
  try {
    process.kill(pid, 0);
  } catch (err) {
    const code = (err as NodeJS.ErrnoException).code;
    if (code === "ESRCH") alive = false;
  }
  assert.equal(alive, false, `expected child process ${pid} to be reaped`);
}

test("empty directory, nested directories, small and large files match TS oracle field-for-field", async () => {
  const empty = freshDir();
  assert.deepEqual(await candidateMeasureRoom(empty), await measureRoomReference(empty));
  assert.equal(await candidateMeasured(empty), await measuredReference(empty));
  assert.deepEqual(await candidateMeasuredUpTo(empty, Number.MAX_SAFE_INTEGER), await measuredUpToReference(empty, Number.MAX_SAFE_INTEGER));

  const nested = freshDir();
  writeSized(join(nested, "zero.bin"), 0);
  writeSized(join(nested, "tiny.txt"), 13);
  writeSized(join(nested, "a/b/c/d/medium.bin"), 64 * 1024);
  writeSized(join(nested, "blobs/large.bin"), 512 * 1024);
  writeSized(join(nested, "pkg/node_modules/dep/index.js"), 16 * 1024);
  writeSized(join(nested, "rs/Cargo.toml"), 64);
  writeSized(join(nested, "rs/target/debug/app"), 32 * 1024);
  writeSized(join(nested, ".git/node_modules/ignored"), 4 * 1024);
  writeSized(join(nested, "uploads/node_modules/ignored"), 4 * 1024);

  const [gotRoom, refRoom] = [await candidateMeasureRoom(nested), await measureRoomReference(nested)];
  assert.deepEqual(gotRoom, refRoom);
  assert.deepEqual(
    gotRoom.rebuild.map(([p]) => p.slice(nested.length + 1)).sort(),
    ["pkg/node_modules", "rs/target"],
  );
  assert.equal(await candidateMeasured(nested), await measuredReference(nested));
  assert.ok(gotRoom.bytes >= 512 * 1024);
});

test("hard links to the same inode are deduplicated and counted once", async () => {
  const root = freshDir();
  const payloadBytes = 128 * 1024;
  writeSized(join(root, "primary/blob.bin"), payloadBytes);
  mkdirSync(join(root, "copies"), { recursive: true });
  mkdirSync(join(root, "app/node_modules/pkg"), { recursive: true });
  linkSync(join(root, "primary/blob.bin"), join(root, "copies/link1.bin"));
  linkSync(join(root, "primary/blob.bin"), join(root, "copies/link2.bin"));
  linkSync(join(root, "primary/blob.bin"), join(root, "app/node_modules/pkg/link3.bin"));

  const [gotRoom, refRoom] = [await candidateMeasureRoom(root), await measureRoomReference(root)];
  assert.deepEqual(gotRoom, refRoom);
  const singleDiskBytes = await candidateMeasured(join(root, "primary/blob.bin"));
  assert.ok(singleDiskBytes >= payloadBytes, `single file disk bytes ${singleDiskBytes} >= ${payloadBytes}`);
  // Four hard links to the same 128 KiB file must not multiply its footprint.
  assert.ok(
    gotRoom.bytes < singleDiskBytes * 2,
    `expected deduplicated bytes (${gotRoom.bytes}) < 2x single file (${singleDiskBytes * 2})`,
  );
});

test("symlinks (dangling, directory, circular) are not followed and never loop", async () => {
  const root = freshDir();
  const outside = freshDir("footprint-outside-");
  writeSized(join(outside, "huge.bin"), 256 * 1024);
  writeSized(join(outside, "node_modules/pkg/big.js"), 128 * 1024);
  writeSized(join(root, "src/index.ts"), 1024);

  symlinkSync(join(root, "does-not-exist"), join(root, "dangling-link"));
  symlinkSync(outside, join(root, "outside-dir-link"));
  symlinkSync(root, join(root, "src/circular-root-link"));

  const [gotRoom, refRoom] = [await candidateMeasureRoom(root), await measureRoomReference(root)];
  assert.deepEqual(gotRoom, refRoom);
  assert.equal(gotRoom.complete, true);
  assert.deepEqual(gotRoom.rebuild, []);
  assert.ok(gotRoom.bytes < 256 * 1024, `external symlink target must not be counted (got ${gotRoom.bytes})`);
});

test("budget limits (maxEntries, stopAfter, depth > 32) match TS oracle", async () => {
  const root = freshDir();
  for (let i = 0; i < 12; i++) writeSized(join(root, `dir-${i}/file.bin`), 8192);
  writeSized(join(root, "app/node_modules/a/b.js"), 16384);

  for (const maxEntries of [0, 1, 5, 10, 20]) {
    assert.deepEqual(
      await candidateMeasureRoom(root, { maxEntries }),
      await measureRoomReference(root, { maxEntries }),
      `maxEntries=${maxEntries}`,
    );
  }

  const total = await candidateMeasured(root);
  for (const limit of [0, 1, 4096, Math.floor(total / 2), total - 1, total]) {
    const [got, ref] = [
      await candidateMeasuredUpTo(root, limit),
      await measuredUpToReference(root, limit),
    ];
    assert.deepEqual(got, { bytes: ref.bytes, complete: ref.complete, ...(ref.truncated ? { truncated: true } : {}) }, `limit=${limit}`);
  }

  const deepRoot = freshDir();
  let cur = deepRoot;
  for (let i = 0; i < 38; i++) cur = join(cur, `d${i}`);
  writeSized(join(cur, "leaf.bin"), 4096);
  const [deepGot, deepRef] = [
    await candidateMeasureRoom(deepRoot),
    await measureRoomReference(deepRoot),
  ];
  assert.deepEqual(deepGot, deepRef);
  assert.equal(deepGot.complete, false);
  assert.equal(deepGot.reason, "depth");
});

test("unreadable subdirectory (chmod 0o000): strict fails with EACCES, non-strict skips and cleans up", async () => {
  const root = freshDir();
  writeSized(join(root, "visible/a.txt"), 4096);
  const locked = join(root, "locked");
  writeSized(join(locked, "secret.txt"), 16384);

  const canEnforcePerms = platform.os !== "windows" && process.getuid?.() !== 0;
  if (canEnforcePerms) {
    chmodSync(locked, 0o000);
  }
  try {
    if (canEnforcePerms) {
      const catchErr = (p: Promise<unknown>) =>
        p.then(
          () => null,
          (e: NodeJS.ErrnoException) => ({ code: e.code, message: e.message }),
        );
      const [gotErr, refErr] = [
        await catchErr(candidateMeasuredUpTo(root, Number.MAX_SAFE_INTEGER, MEASURE_UP_TO, true)),
        await catchErr(measuredUpToReference(root, Number.MAX_SAFE_INTEGER)),
      ];
      assert.deepEqual(gotErr, refErr);
      assert.equal(gotErr?.code, "EACCES");
    }

    assert.equal(await candidateMeasured(root), await measuredReference(root));
    assert.deepEqual(await candidateMeasureRoom(root), await measureRoomReference(root));
  } finally {
    if (canEnforcePerms) {
      chmodSync(locked, 0o755);
    }
  }
});

test("cancellation and termination: stdin EOF and SIGTERM exit cleanly with zero zombies", async () => {
  // 1) Closing stdin immediately without a request exits cleanly with code 0.
  const eofExit = await new Promise<{ pid: number; code: number | null; signal: NodeJS.Signals | null }>((resolve, reject) => {
    const child = spawn(CANDIDATE, ["--builder", "footprint", "--sep", sep], {
      stdio: ["pipe", "pipe", "pipe"],
      windowsHide: true,
    });
    const pid = child.pid!;
    assert.ok(pid > 0);
    child.on("error", reject);
    child.on("close", (code, signal) => resolve({ pid, code, signal }));
    child.stdin!.end();
  });
  assert.equal(eofExit.code, 0);
  assert.equal(eofExit.signal, null);
  assertProcessGone(eofExit.pid);

  // 2) SIGTERM while waiting for stdin terminates promptly with no zombie.
  const sigtermIdle = await new Promise<{ pid: number; code: number | null; signal: NodeJS.Signals | null }>((resolve, reject) => {
    const child = spawn(CANDIDATE, ["--builder", "footprint", "--sep", sep], {
      stdio: ["pipe", "pipe", "pipe"],
      windowsHide: true,
    });
    const pid = child.pid!;
    assert.ok(pid > 0);
    child.on("error", reject);
    child.on("close", (code, signal) => resolve({ pid, code, signal }));
    child.kill("SIGTERM");
  });
  assert.ok(sigtermIdle.signal === "SIGTERM" || sigtermIdle.code !== 0);
  assertProcessGone(sigtermIdle.pid);

  // 3) SIGTERM during an active walk terminates promptly with no zombie.
  const bigTree = freshDir();
  for (let d = 0; d < 10; d++) {
    for (let f = 0; f < 50; f++) {
      writeSized(join(bigTree, `d${d}`, `f${f}`), 16);
    }
  }
  const sigtermActive = await new Promise<{ pid: number; code: number | null; signal: NodeJS.Signals | null }>((resolve, reject) => {
    const child = spawn(CANDIDATE, ["--builder", "footprint", "--sep", sep], {
      stdio: ["pipe", "pipe", "pipe"],
      windowsHide: true,
    });
    const pid = child.pid!;
    assert.ok(pid > 0);
    child.stdin!.on("error", () => {});
    child.on("error", reject);
    child.on("close", (code, signal) => resolve({ pid, code, signal }));
    child.stdin!.write(`${JSON.stringify({ path: bigTree, base: normalize(bigTree), finding: true, strict: false })}\n`);
    child.kill("SIGTERM");
  });
  assert.ok(sigtermActive.signal === "SIGTERM" || sigtermActive.code !== null);
  assertProcessGone(sigtermActive.pid);
});

test("invalid CLI arguments, malformed JSON requests, and missing paths follow error contract", async () => {
  // Missing path: both strict and non-strict return zero size, complete: true.
  const missing = join(freshDir(), "does-not-exist");
  assert.deepEqual(await candidateMeasureRoom(missing), { bytes: 0, rebuild: [], complete: true });
  assert.deepEqual(await candidateMeasuredUpTo(missing, 1024, MEASURE_UP_TO, true), { bytes: 0, complete: true });

  // Malformed JSON line
  const badJson = await invokeFootprintRaw("{not valid json\n");
  assert.equal(badJson.exitCode, 0);
  assert.deepEqual(badJson.messages, [{ error: "not JSON", code: "EINVAL" }]);

  // Non-object JSON
  const nonObject = await invokeFootprintRaw("[1,2,3]\n");
  assert.equal(nonObject.exitCode, 0);
  assert.deepEqual(nonObject.messages, [{ error: "not an object", code: "EINVAL" }]);

  // Missing required `path` field
  const noPath = await invokeFootprintRaw('{"finding":true}\n');
  assert.equal(noPath.exitCode, 0);
  assert.deepEqual(noPath.messages, [{ error: "path is required", code: "EINVAL" }]);

  // Invalid CLI arguments exit with code 2 and usage message on stderr.
  const badCli = await new Promise<{ code: number | null; stderr: string }>((resolve, reject) => {
    const child = spawn(CANDIDATE, ["--builder", "no-such-builder-xyz"], {
      stdio: ["pipe", "pipe", "pipe"],
      windowsHide: true,
    });
    let stderr = "";
    child.stderr!.on("data", (chunk: Buffer) => { stderr += chunk.toString("utf8"); });
    child.on("error", reject);
    child.on("close", (code) => resolve({ code, stderr }));
    child.stdin!.end();
  });
  assert.equal(badCli.code, 2);
  assert.match(badCli.stderr, /usage:/i);
});
