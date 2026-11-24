// Black-box contract tests for `--builder footprint` against any reader binary.
//
// By default this runs against the shipped MoonBit `stillfail-reader` (`mbReaderBinary()`).
// Set `STILLFAIL_READER_CANDIDATE=/path/to/stillfail-pion` to verify a candidate binary
// with zero edits to this suite. Never silently skips when the binary is missing.
//
// A `CACHEDIR.TAG` that is not a regular file (a FIFO with no writer, or a link to one) is refused
// at once and never read: no reader waits on it (`sff_head`, footprint.ts `answerSoon`).
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { chmodSync, existsSync, linkSync, mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, normalize, sep } from "node:path";
import { after, test } from "node:test";
import { platform } from "../src/platform/index.ts";
import { MbProcess, mbReaderBinary } from "../src/read/mb-reader.ts";
import { CARGO_TAG, MEASURE_ROOM, MEASURE_UP_TO, type MeasureBudget, measured, rebuildableSoon, type Room } from "../src/sessions/footprint.ts";
import { measureRoomReference, measuredReference, measuredUpToReference, rebuildableKind } from "./footprint-reference.ts";
import { measuredMounted, noMounts } from "./footprint-mounts.ts";

const CHILD_TIMEOUT_MS = 15_000;

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

/**
 * Strict JSON-line + optional `{ bytes }` body frame parser for contract tests.
 * Unlike production `Said`, this never swallows malformed lines and asserts zero trailing garbage at EOF.
 */
class StrictFrameParser {
  #buf: Buffer = Buffer.alloc(0);
  #pendingHead: Record<string, unknown> | null = null;
  #wantedBytes = 0;
  readonly messages: unknown[] = [];

  push(chunk: Buffer): void {
    this.#buf = this.#buf.length === 0 ? chunk : Buffer.concat([this.#buf, chunk]);
    while (this.#buf.length > 0) {
      if (this.#pendingHead !== null) {
        if (this.#buf.length < this.#wantedBytes) return;
        const body = this.#buf.subarray(0, this.#wantedBytes);
        this.#buf = this.#buf.subarray(this.#wantedBytes);
        const head = this.#pendingHead;
        this.#pendingHead = null;
        this.#wantedBytes = 0;
        this.messages.push({ ...head, body });
        continue;
      }
      const nl = this.#buf.indexOf(10);
      if (nl < 0) return;
      const line = this.#buf.subarray(0, nl).toString("utf8");
      this.#buf = this.#buf.subarray(nl + 1);
      assert.notEqual(line, "", "unexpected empty line on stdout");
      let parsed: unknown;
      try {
        parsed = JSON.parse(line);
      } catch (err) {
        assert.fail(`stdout emitted non-JSON line: ${JSON.stringify(line)} (${(err as Error).message})`);
      }
      const wanted = (parsed as { bytes?: unknown } | null)?.bytes;
      if (typeof wanted === "number" && Number.isInteger(wanted) && wanted >= 0) {
        const { bytes: _, ...rest } = parsed as Record<string, unknown>;
        this.#pendingHead = rest;
        this.#wantedBytes = wanted;
        if (wanted === 0) {
          this.#pendingHead = null;
          this.messages.push({ ...rest, body: Buffer.alloc(0) });
        }
        continue;
      }
      this.messages.push(parsed);
    }
  }

  assertCleanEof(): void {
    assert.equal(this.#pendingHead, null, `truncated framed body at EOF (wanted ${this.#wantedBytes} bytes)`);
    assert.equal(
      this.#buf.length,
      0,
      `trailing non-terminated bytes on stdout at EOF: ${JSON.stringify(this.#buf.toString("utf8"))}`,
    );
  }
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

/**
 * Invoke `--builder footprint` matching production lifecycle (`sessions/footprint.ts`):
 * writes one JSON line and KEEPS `stdin` OPEN so the binary must respond and exit on its own
 * without waiting for stdin EOF.
 */
async function invokeFootprintRaw(rawLine: string): Promise<RawInvocation> {
  return await new Promise<RawInvocation>((resolve, reject) => {
    const child = spawn(CANDIDATE, ["--builder", "footprint", "--sep", sep], {
      stdio: ["pipe", "pipe", "pipe"],
      windowsHide: true,
    });
    const pid = child.pid;
    assert.ok(typeof pid === "number" && pid > 0, "expected a real child process pid");
    const parser = new StrictFrameParser();
    let stderr = "";
    let parseError: Error | null = null;
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      reject(new Error(`footprint process ${pid} timed out after ${CHILD_TIMEOUT_MS}ms (stderr: ${stderr})`));
    }, CHILD_TIMEOUT_MS);

    child.stdout!.on("data", (chunk: Buffer) => {
      if (parseError !== null) return;
      try {
        parser.push(chunk);
      } catch (err) {
        parseError = err as Error;
        child.kill("SIGKILL");
      }
    });
    child.stderr!.on("data", (chunk: Buffer) => { stderr += chunk.toString("utf8"); });
    child.stdin!.on("error", () => {});
    child.on("error", (err) => {
      clearTimeout(timer);
      reject(err);
    });
    child.on("close", (exitCode, signal) => {
      clearTimeout(timer);
      if (parseError !== null) return reject(parseError);
      try {
        parser.assertCleanEof();
      } catch (err) {
        return reject(err);
      }
      resolve({ pid, messages: parser.messages, stderr, exitCode, signal });
    });
    // Keep stdin open (production behavior): do NOT call stdin.end().
    child.stdin!.write(rawLine);
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

test("budget limits (maxEntries, stopAfter, depth > 32, maxDurationMs: 0) match TS oracle", async () => {
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

  // Deterministic duration truncation with maxDurationMs: 0 on a sufficiently large tree
  const durationRoot = freshDir();
  for (let d = 0; d < 20; d++) {
    for (let f = 0; f < 100; f++) {
      writeSized(join(durationRoot, `d${d}`, `f${f}`), 16);
    }
  }
  const durationRoom = await candidateMeasureRoom(durationRoot, { maxDurationMs: 0 });
  assert.equal(durationRoom.complete, false);
  assert.equal(durationRoom.reason, "duration");
});

test("unreadable subdirectory (chmod 0o000): strict fails with EACCES, non-strict skips and cleans up", async (t) => {
  if (platform.os === "windows" || process.getuid?.() === 0) {
    t.skip("requires non-root POSIX permissions");
    return;
  }
  const root = freshDir();
  writeSized(join(root, "visible/a.txt"), 4096);
  const locked = join(root, "locked");
  writeSized(join(locked, "secret.txt"), 16384);

  chmodSync(locked, 0o000);
  try {
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

    assert.equal(await candidateMeasured(root), await measuredReference(root));
    assert.deepEqual(await candidateMeasureRoom(root), await measureRoomReference(root));
  } finally {
    chmodSync(locked, 0o755);
  }
});

test("a CACHEDIR.TAG that is a FIFO (or a link to one) is refused at once; a regular one (or a link to one) still marks a Cargo target", async (t) => {
  if (process.platform === "win32") return t.skip("mkfifo: no FIFOs on Windows");
  const root = freshDir();
  const cargoDir = (name: string) => {
    writeSized(join(root, name, "debug/deps/app.d"), 2048);
    writeSized(join(root, name, "debug/.fingerprint/app/hash"), 64);
    writeFileSync(join(root, name, ".rustc_info.json"), "{}");
    writeSized(join(root, name, "notes.bin"), 4096);
    return join(root, name);
  };
  const fifoDir = cargoDir("fifo-target");
  const made = spawnSync("mkfifo", [join(fifoDir, "CACHEDIR.TAG")]);
  assert.equal(made.status, 0, `mkfifo failed: ${made.stderr}`);
  const fifoLinkDir = cargoDir("fifo-link-target");
  symlinkSync(join(fifoDir, "CACHEDIR.TAG"), join(fifoLinkDir, "CACHEDIR.TAG"));
  const regularDir = cargoDir("regular-target");
  writeFileSync(join(regularDir, "CACHEDIR.TAG"), `${CARGO_TAG.join("\n")}\n`);
  const regularLinkDir = cargoDir("regular-link-target");
  symlinkSync(join(regularDir, "CACHEDIR.TAG"), join(regularLinkDir, "CACHEDIR.TAG"));

  // The station's own probe (off the thread) and the reference's (at once) each decide every directory.
  for (const dir of [fifoDir, fifoLinkDir]) {
    assert.equal(await rebuildableSoon(dir), null, `${dir}: a FIFO CACHEDIR.TAG is not a Cargo target's`);
    assert.equal(rebuildableKind(dir), null, `${dir}: a FIFO CACHEDIR.TAG is not a Cargo target's (reference)`);
  }
  for (const dir of [regularDir, regularLinkDir]) {
    assert.equal(await rebuildableSoon(dir), "found");
    assert.equal(rebuildableKind(dir), "found");
  }

  // The reader (bounded by CHILD_TIMEOUT_MS: it must answer, not wait on the FIFO) matches the reference field for field.
  const [gotRoom, refRoom] = [await candidateMeasureRoom(root), await measureRoomReference(root)];
  assert.deepEqual(gotRoom, refRoom);
  assert.equal(gotRoom.complete, true);
  assert.deepEqual(gotRoom.rebuild.map(([p]) => p).sort(), [regularDir, regularLinkDir].sort());
  assert.equal(await candidateMeasured(root), await measuredReference(root));
  assert.deepEqual(
    await candidateMeasuredUpTo(root, Number.MAX_SAFE_INTEGER),
    await measuredUpToReference(root, Number.MAX_SAFE_INTEGER),
  );
  // The FIFO's directory measured on its own, as a room (its CACHEDIR.TAG only looked at, never waited on).
  assert.deepEqual(await candidateMeasureRoom(fifoDir), await measureRoomReference(fifoDir));
});

test("cancellation and termination: pre-aborted AbortSignal, stdin EOF, and idle SIGTERM exit cleanly with zero zombies", async () => {
  // 1) Pre-aborted AbortSignal on production `measured()` rejects immediately without spawning a child process.
  const dir = freshDir();
  writeSized(join(dir, "a.bin"), 4096);
  const preAborted = new AbortController();
  preAborted.abort(new Error("cancelled before start"));
  const beforeLive = MbProcess.live().filter((p) => p.args.includes("footprint")).length;
  await assert.rejects(measured(dir, preAborted.signal), /cancelled before start/);
  const afterLive = MbProcess.live().filter((p) => p.args.includes("footprint")).length;
  assert.equal(afterLive, beforeLive, "pre-aborted measured() must not spawn a footprint process");

  // 2) Closing stdin without a request exits cleanly with code 0 and no output.
  const eofExit = await new Promise<{ pid: number; code: number | null; signal: NodeJS.Signals | null; stdout: string }>((resolve, reject) => {
    const child = spawn(CANDIDATE, ["--builder", "footprint", "--sep", sep], {
      stdio: ["pipe", "pipe", "pipe"],
      windowsHide: true,
    });
    const pid = child.pid!;
    assert.ok(pid > 0);
    let stdout = "";
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      reject(new Error(`footprint EOF test timed out for pid ${pid}`));
    }, CHILD_TIMEOUT_MS);
    child.stdout!.on("data", (c: Buffer) => { stdout += c.toString("utf8"); });
    child.stderr!.resume();
    child.on("error", (err) => { clearTimeout(timer); reject(err); });
    child.on("close", (code, signal) => { clearTimeout(timer); resolve({ pid, code, signal, stdout }); });
    child.stdin!.end();
  });
  assert.equal(eofExit.code, 0);
  assert.equal(eofExit.signal, null);
  assert.equal(eofExit.stdout, "");
  assertProcessGone(eofExit.pid);

  // 3) SIGTERM while waiting for stdin terminates with SIGTERM, emits no response, and leaves zero zombies.
  const sigtermIdle = await new Promise<{ pid: number; code: number | null; signal: NodeJS.Signals | null; stdout: string }>((resolve, reject) => {
    const child = spawn(CANDIDATE, ["--builder", "footprint", "--sep", sep], {
      stdio: ["pipe", "pipe", "pipe"],
      windowsHide: true,
    });
    const pid = child.pid!;
    assert.ok(pid > 0);
    let stdout = "";
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      reject(new Error(`footprint idle SIGTERM test timed out for pid ${pid}`));
    }, CHILD_TIMEOUT_MS);
    child.stdout!.on("data", (c: Buffer) => { stdout += c.toString("utf8"); });
    child.stderr!.resume();
    child.on("error", (err) => { clearTimeout(timer); reject(err); });
    child.on("close", (code, signal) => { clearTimeout(timer); resolve({ pid, code, signal, stdout }); });
    child.once("spawn", () => {
      child.kill("SIGTERM");
    });
  });
  assert.equal(sigtermIdle.stdout, "");
  assert.equal(sigtermIdle.signal, "SIGTERM");
  assertProcessGone(sigtermIdle.pid);
});

test("a file system really mounted in a room, whatever its name, is counted as itself, never looked into nor found, as the TS oracle", { skip: noMounts() }, () => {
  const root = freshDir();
  writeSized(join(root, "web/node_modules/y.js"), 3_000);
  const { got, reference, visible } = measuredMounted(root, CANDIDATE);
  assert.deepEqual(got, reference);
  assert.deepEqual(got.rebuild.map(([p]) => p.slice(root.length + 1)), [join("web", "node_modules")]);
  assert.equal(got.bytes, visible);
  assert.equal(got.complete, true);
});

test("a path or a base with a NUL in it is refused EINVAL, never measured as the path before the NUL", async () => {
  const root = freshDir();
  writeSized(join(root, "node_modules/pkg/index.js"), 16_384);
  // (a bad path with a good base too: refused for the path itself, not for a base taken from it)
  for (const ask of [{ path: `${root}\0${sep}none` }, { path: `${root}\0${sep}none`, base: root }, { path: root, base: `${root}\0x` }]) {
    for (const finding of [true, false]) {
      const inv = await invokeFootprintRaw(`${JSON.stringify({ ...ask, finding, strict: !finding })}\n`);
      assert.equal(inv.exitCode, 0, `footprint exited with ${inv.exitCode} (stderr: ${inv.stderr})`);
      assert.equal(inv.messages.length, 1);
      const [said] = inv.messages as FootprintRawResponse[];
      assert.deepEqual(said, { error: "path must not contain NUL bytes", code: "EINVAL" });
    }
  }
});

test("invalid CLI arguments, malformed JSON requests, and missing paths follow error contract", async () => {
  const missing = join(freshDir(), "does-not-exist");
  assert.deepEqual(await candidateMeasureRoom(missing), { bytes: 0, rebuild: [], complete: true });
  assert.deepEqual(await candidateMeasuredUpTo(missing, 1024, MEASURE_UP_TO, true), { bytes: 0, complete: true });

  const badJson = await invokeFootprintRaw("{not valid json\n");
  assert.equal(badJson.exitCode, 0);
  assert.deepEqual(badJson.messages, [{ error: "not JSON", code: "EINVAL" }]);

  const nonObject = await invokeFootprintRaw("[1,2,3]\n");
  assert.equal(nonObject.exitCode, 0);
  assert.deepEqual(nonObject.messages, [{ error: "not an object", code: "EINVAL" }]);

  const noPath = await invokeFootprintRaw('{"finding":true}\n');
  assert.equal(noPath.exitCode, 0);
  assert.deepEqual(noPath.messages, [{ error: "path is required", code: "EINVAL" }]);

  // Unterminated fragment at stdin EOF exits 0 quietly without responding (matches MoonBit host.line).
  const unterminatedEof = await new Promise<{ code: number | null; signal: NodeJS.Signals | null; stdout: string }>((resolve, reject) => {
    const child = spawn(CANDIDATE, ["--builder", "footprint", "--sep", sep], {
      stdio: ["pipe", "pipe", "pipe"],
      windowsHide: true,
    });
    let stdout = "";
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      reject(new Error("unterminated EOF test timed out"));
    }, CHILD_TIMEOUT_MS);
    child.stdout!.on("data", (c: Buffer) => { stdout += c.toString("utf8"); });
    child.stderr!.resume();
    child.on("error", (err) => { clearTimeout(timer); reject(err); });
    child.on("close", (code, signal) => { clearTimeout(timer); resolve({ code, signal, stdout }); });
    child.stdin!.end('{"path":"/tmp"}');
  });
  assert.equal(unterminatedEof.code, 0);
  assert.equal(unterminatedEof.signal, null);
  assert.equal(unterminatedEof.stdout, "");

  const badCli = await new Promise<{ code: number | null; stderr: string }>((resolve, reject) => {
    const child = spawn(CANDIDATE, ["--builder", "no-such-builder-xyz"], {
      stdio: ["pipe", "pipe", "pipe"],
      windowsHide: true,
    });
    let stderr = "";
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      reject(new Error("bad CLI args test timed out"));
    }, CHILD_TIMEOUT_MS);
    child.stdout!.resume();
    child.stderr!.on("data", (chunk: Buffer) => { stderr += chunk.toString("utf8"); });
    child.on("error", (err) => { clearTimeout(timer); reject(err); });
    child.on("close", (code) => { clearTimeout(timer); resolve({ code, stderr }); });
    child.stdin!.end();
  });
  assert.equal(badCli.code, 2);
  assert.match(badCli.stderr, /usage:/i);
});

test("UTF-8 CJK filenames and invalid non-UTF-8 POSIX filenames match TS oracle 0-diff", async () => {
  const root = freshDir();
  writeSized(join(root, "中文目录/测试文件.txt"), 8192);
  writeSized(join(root, "中文项目/node_modules/依赖/index.js"), 16384);

  // On Linux POSIX filesystems that allow raw non-UTF-8 entry names, create `f\xff\xfe/`
  // containing a file and `node_modules` to verify WHATWG lossy UTF-8 parity with Node/MB.
  let createdRawNonUtf8 = false;
  if (platform.os === "linux") {
    try {
      const rawDir = Buffer.concat([Buffer.from(root, "utf8"), Buffer.from("/f", "utf8"), Buffer.from([0xff, 0xfe])]);
      mkdirSync(rawDir);
      const rawFile = Buffer.concat([rawDir, Buffer.from("/data.bin", "utf8")]);
      writeFileSync(rawFile, Buffer.alloc(32768, 0x42));
      const rawNm = Buffer.concat([rawDir, Buffer.from("/node_modules", "utf8")]);
      mkdirSync(rawNm);
      writeFileSync(Buffer.concat([rawNm, Buffer.from("/dep.js", "utf8")]), Buffer.alloc(16384, 0x43));
      createdRawNonUtf8 = true;
    } catch {
      createdRawNonUtf8 = false;
    }
  }

  const [gotRoom, refRoom] = [await candidateMeasureRoom(root), await measureRoomReference(root)];
  assert.deepEqual(gotRoom, refRoom);
  assert.equal(await candidateMeasured(root), await measuredReference(root));
  assert.deepEqual(
    await candidateMeasuredUpTo(root, Number.MAX_SAFE_INTEGER),
    await measuredUpToReference(root, Number.MAX_SAFE_INTEGER),
  );
  assert.ok(gotRoom.rebuild.some(([p]) => p.endsWith("中文项目/node_modules") || p.endsWith("中文项目\\node_modules")));
  if (platform.os === "linux") {
    assert.equal(createdRawNonUtf8, true, "expected Linux tmpfs/ext4 to allow raw non-UTF-8 filename creation");
  }
});
