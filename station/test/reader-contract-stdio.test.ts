// Black-box stdio framing and lifecycle contract tests for any `stillfail-reader` binary.
//
// Targets `STILLFAIL_READER_CANDIDATE` when set, otherwise the shipped MoonBit `stillfail-reader`
// (`mbReaderBinary()`). Never silently skips when the binary is missing.
import assert from "node:assert/strict";
import { type ChildProcess, spawn } from "node:child_process";
import { existsSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, normalize, sep } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { after, test } from "node:test";
import { mbReaderBinary } from "../src/read/mb-reader.ts";

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
    rmSync(dir, { recursive: true, force: true });
  }
});

function freshDataDir(): string {
  const dir = mkdtempSync(join(tmpdir(), "stdio-contract-"));
  tempDirs.push(dir);
  const db = new DatabaseSync(join(dir, "stillfail.db"));
  db.exec("PRAGMA journal_mode = WAL; CREATE TABLE kv (k TEXT PRIMARY KEY, v TEXT);");
  db.close();
  return dir;
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

/**
 * Strict JSON-line + `{ bytes }` body frame parser.
 * Rejects any non-JSON stdout line and asserts zero trailing partial bytes on EOF.
 */
class StrictFrameParser {
  #buf: Buffer = Buffer.alloc(0);
  #pendingHead: Record<string, unknown> | null = null;
  #wantedBytes = 0;
  readonly #onMessage: (msg: Record<string, unknown>) => void;

  constructor(onMessage: (msg: Record<string, unknown>) => void) {
    this.#onMessage = onMessage;
  }

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
        this.#onMessage({ ...head, body });
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
      assert.ok(parsed !== null && typeof parsed === "object" && !Array.isArray(parsed), `expected JSON object line, got ${line}`);
      const obj = parsed as Record<string, unknown>;
      const wanted = obj.bytes;
      if (typeof wanted === "number" && Number.isInteger(wanted) && wanted >= 0) {
        const { bytes: _, ...rest } = obj;
        this.#pendingHead = rest;
        this.#wantedBytes = wanted;
        if (wanted === 0) {
          this.#pendingHead = null;
          this.#onMessage({ ...rest, body: Buffer.alloc(0) });
        }
        continue;
      }
      this.#onMessage(obj);
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

type FramedClient = {
  child: ChildProcess;
  pid: number;
  nextMessage(): Promise<Record<string, unknown>>;
  writeRaw(chunk: string | Buffer): void;
  endAndWait(): Promise<{ code: number | null; signal: NodeJS.Signals | null }>;
  terminateAndWait(sig: NodeJS.Signals): Promise<{ code: number | null; signal: NodeJS.Signals | null }>;
  kill(): void;
};

function spawnDataReader(dataDir: string): FramedClient {
  const child = spawn(CANDIDATE, ["--data", dataDir, "--sep", sep], {
    stdio: ["pipe", "pipe", "pipe"],
    windowsHide: true,
  });
  const pid = child.pid;
  assert.ok(typeof pid === "number" && pid > 0, "expected a real child process pid");

  const queue: Record<string, unknown>[] = [];
  const waiters: ((msg: Record<string, unknown>) => void)[] = [];
  const rejecters: ((err: Error) => void)[] = [];
  let closed = false;
  let fatalError: Error | null = null;
  let stderr = "";
  let closeResult: { code: number | null; signal: NodeJS.Signals | null } | null = null;
  const closeWaiters: { resolve: (res: { code: number | null; signal: NodeJS.Signals | null }) => void; reject: (err: Error) => void }[] = [];

  const failAll = (err: Error) => {
    fatalError ??= err;
    for (const reject of rejecters.splice(0)) reject(fatalError);
    waiters.splice(0);
    for (const w of closeWaiters.splice(0)) w.reject(fatalError);
  };

  const assertNoUnsolicited = () => {
    if (queue.length > 0) {
      const err = new assert.AssertionError({
        message: `unexpected unsolicited frame(s) received before close: ${JSON.stringify(queue)}`,
        actual: queue.length,
        expected: 0,
      });
      fatalError ??= err;
      throw err;
    }
  };

  const parser = new StrictFrameParser((record) => {
    const waiter = waiters.shift();
    rejecters.shift();
    if (waiter) waiter(record);
    else queue.push(record);
  });

  child.stdout!.on("data", (chunk: Buffer) => {
    if (fatalError !== null) return;
    try {
      parser.push(chunk);
    } catch (err) {
      child.kill("SIGKILL");
      failAll(err as Error);
    }
  });
  child.stderr!.on("data", (chunk: Buffer) => { stderr += chunk.toString("utf8"); });
  child.stdin!.on("error", () => {});
  child.on("close", (code, signal) => {
    closed = true;
    closeResult = { code, signal };
    if (fatalError !== null) return;
    try {
      parser.assertCleanEof();
    } catch (err) {
      failAll(err as Error);
      return;
    }
    for (const reject of rejecters.splice(0)) {
      reject(new Error(`reader exited unexpectedly (code=${code}, signal=${signal}, stderr=${stderr})`));
    }
    waiters.splice(0);
    for (const w of closeWaiters.splice(0)) {
      try {
        assertNoUnsolicited();
        w.resolve(closeResult);
      } catch (err) {
        w.reject(err as Error);
      }
    }
  });

  const withTimeout = <T>(p: Promise<T>, label: string): Promise<T> =>
    new Promise<T>((resolve, reject) => {
      const timer = setTimeout(() => {
        if (!closed) child.kill("SIGKILL");
        reject(new Error(`${label} timed out after ${CHILD_TIMEOUT_MS}ms (pid=${pid}, stderr=${stderr})`));
      }, CHILD_TIMEOUT_MS);
      p.then(
        (v) => { clearTimeout(timer); resolve(v); },
        (e) => { clearTimeout(timer); reject(e); },
      );
    });

  return {
    child,
    pid,
    nextMessage() {
      if (fatalError !== null) return Promise.reject(fatalError);
      if (queue.length > 0) return Promise.resolve(queue.shift()!);
      if (closed) return Promise.reject(new Error("reader already exited"));
      return withTimeout(
        new Promise((resolve, reject) => {
          waiters.push(resolve);
          rejecters.push(reject);
        }),
        "nextMessage",
      );
    },
    writeRaw(chunk: string | Buffer) {
      child.stdin!.write(chunk);
    },
    endAndWait() {
      if (fatalError !== null) return Promise.reject(fatalError);
      if (closed && closeResult) {
        try {
          assertNoUnsolicited();
          return Promise.resolve(closeResult);
        } catch (err) {
          return Promise.reject(err);
        }
      }
      return withTimeout(
        new Promise((resolve, reject) => {
          closeWaiters.push({ resolve, reject });
          child.stdin!.end();
        }),
        "endAndWait",
      );
    },
    terminateAndWait(sig: NodeJS.Signals) {
      if (fatalError !== null) return Promise.reject(fatalError);
      if (closed && closeResult) {
        try {
          assertNoUnsolicited();
          return Promise.resolve(closeResult);
        } catch (err) {
          return Promise.reject(err);
        }
      }
      return withTimeout(
        new Promise((resolve, reject) => {
          closeWaiters.push({ resolve, reject });
          child.kill(sig);
        }),
        `terminateAndWait(${sig})`,
      );
    },
    kill() {
      if (!closed) child.kill("SIGKILL");
    },
  };
}

const nextTick = () => new Promise<void>((resolve) => setImmediate(resolve));

function assertReadyMessage(msg: Record<string, unknown>): void {
  const ready = msg.ready as Record<string, unknown> | undefined;
  assert.ok(ready !== null && ready !== undefined && typeof ready === "object", `expected ready object, got ${JSON.stringify(msg)}`);
  assert.ok(typeof ready.loadedMs === "number" && Number.isFinite(ready.loadedMs) && ready.loadedMs >= 0, `invalid loadedMs: ${ready.loadedMs}`);
  assert.ok(typeof ready.openedMs === "number" && Number.isFinite(ready.openedMs) && ready.openedMs >= 0, `invalid openedMs: ${ready.openedMs}`);
}

test("data reader: startup ready handshake, empty lines ignored, mid-UTF8 fragmented writes with true echo, clean EOF exit", async () => {
  const dataDir = freshDataDir();
  const client = spawnDataReader(dataDir);
  try {
    // 1) Startup ready handshake with numeric loadedMs/openedMs
    assertReadyMessage(await client.nextMessage());

    // 2) Blank lines are ignored and do not elicit spurious responses
    client.writeRaw("\n\n\n");

    // 3) Fragmented write split RIGHT IN THE MIDDLE of the 4-byte UTF-8 sequence for 🚀,
    // placed in `op` so the binary's error response MUST echo the exact Unicode string back.
    const unicodeOp = "no_such_op_分片_🚀";
    const reqBuf = Buffer.from(
      `${JSON.stringify({ id: 101, op: unicodeOp, args: {} })}\n`,
      "utf8",
    );
    const rocketBytes = Buffer.from("🚀", "utf8");
    const rocketOffset = reqBuf.indexOf(rocketBytes);
    assert.ok(rocketOffset > 0, "rocket UTF-8 bytes found in request");
    const splitMidRocket = rocketOffset + 2; // cuts 4-byte UTF-8 sequence in half!

    client.writeRaw(reqBuf.subarray(0, 11));
    await nextTick();
    client.writeRaw(reqBuf.subarray(11, splitMidRocket));
    await nextTick();
    client.writeRaw(reqBuf.subarray(splitMidRocket));

    const echoErr = await client.nextMessage();
    assert.deepEqual(echoErr, {
      id: 101,
      status: 500,
      error: `no read ${unicodeOp}`,
    });

    // 4) Follow-up checkpoint over bytes-framed response while stdin stays open
    client.writeRaw(`${JSON.stringify({ id: 102, op: "checkpoint", args: {}, lang: "en", names: [], processes: [], clientKeys: [] })}\n`);
    const ans = await client.nextMessage();
    assert.equal(ans.id, 102);
    assert.ok(Buffer.isBuffer(ans.body), "checkpoint response uses bytes-framed body");
    const parsed = JSON.parse(ans.body.toString("utf8")) as Record<string, unknown>;
    assert.equal(typeof parsed.busy, "number");
    assert.equal(typeof parsed.log, "number");
    assert.equal(typeof parsed.checkpointed, "number");

    // 5) Clean exit on stdin EOF
    const exit = await client.endAndWait();
    assert.equal(exit.code, 0);
    assert.equal(exit.signal, null);
    assertProcessGone(client.pid);
  } finally {
    client.kill();
  }
});

test("data reader: large JSON payloads (> 128 KiB) and pipelined multi-line writes", async () => {
  const dataDir = freshDataDir();
  const client = spawnDataReader(dataDir);
  try {
    assertReadyMessage(await client.nextMessage());

    const bigBlob = "x".repeat(256 * 1024);
    const req1 = JSON.stringify({
      id: 201,
      op: "checkpoint",
      args: { pad: bigBlob },
      lang: "en",
      names: [],
      processes: [],
      clientKeys: [],
    });
    const req2 = JSON.stringify({
      id: 202,
      op: "unknownLargeOp",
      args: { pad: "y".repeat(64 * 1024) },
    });
    const req3 = JSON.stringify({
      id: 203,
      op: "checkpoint",
      args: {},
      lang: "en",
      names: [],
      processes: [],
      clientKeys: [],
    });

    client.writeRaw(`${req1}\n${req2}\n${req3}\n`);

    const a1 = await client.nextMessage();
    assert.equal(a1.id, 201);
    assert.ok(Buffer.isBuffer(a1.body));

    const a2 = await client.nextMessage();
    assert.deepEqual(a2, { id: 202, status: 500, error: "no read unknownLargeOp" });

    const a3 = await client.nextMessage();
    assert.equal(a3.id, 203);
    assert.ok(Buffer.isBuffer(a3.body));

    const exit = await client.endAndWait();
    assert.equal(exit.code, 0);
    assertProcessGone(client.pid);
  } finally {
    client.kill();
  }
});

test("data reader: invalid JSON and malformed requests return structured errors without crashing", async () => {
  const dataDir = freshDataDir();
  const client = spawnDataReader(dataDir);
  try {
    assertReadyMessage(await client.nextMessage());

    client.writeRaw("{broken json\n");
    const err1 = await client.nextMessage();
    assert.equal(err1.id, null);
    assert.equal(err1.status, 400);
    assert.equal(typeof err1.error, "string");
    assert.match(err1.error as string, /^not JSON:/);

    client.writeRaw('{"id": 301, "args": {}}\n');
    const err2 = await client.nextMessage();
    assert.deepEqual(err2, { id: 301, status: 400, error: "no op" });

    client.writeRaw("[1, 2, 3]\n");
    const err3 = await client.nextMessage();
    assert.deepEqual(err3, { id: null, status: 400, error: "no op" });

    client.writeRaw('{"id": 302, "op": "doesNotExist", "args": {}}\n');
    const err4 = await client.nextMessage();
    assert.deepEqual(err4, { id: 302, status: 500, error: "no read doesNotExist" });

    client.writeRaw(`${JSON.stringify({ id: 303, op: "checkpoint", args: {}, lang: "en", names: [], processes: [], clientKeys: [] })}\n`);
    const ok = await client.nextMessage();
    assert.equal(ok.id, 303);
    assert.ok(Buffer.isBuffer(ok.body));

    const exit = await client.endAndWait();
    assert.equal(exit.code, 0);
    assertProcessGone(client.pid);
  } finally {
    client.kill();
  }
});

test("data reader: SIGTERM after ready handshake exits cleanly with SIGTERM and zero zombies", async () => {
  const dataDir = freshDataDir();
  const client = spawnDataReader(dataDir);
  try {
    assertReadyMessage(await client.nextMessage());
    const exit = await client.terminateAndWait("SIGTERM");
    assert.equal(exit.signal, "SIGTERM");
    assertProcessGone(client.pid);
  } finally {
    client.kill();
  }
});

test("footprint builder: fragmented stdin line reassembly without stdin EOF exits cleanly", async () => {
  const dir = mkdtempSync(join(tmpdir(), "stdio-footprint-"));
  tempDirs.push(dir);
  writeFileSync(join(dir, "hello.txt"), "hello world");

  const result = await new Promise<{ messages: Record<string, unknown>[]; code: number | null; signal: NodeJS.Signals | null; pid: number }>((resolve, reject) => {
    const child = spawn(CANDIDATE, ["--builder", "footprint", "--sep", sep], {
      stdio: ["pipe", "pipe", "pipe"],
      windowsHide: true,
    });
    const pid = child.pid!;
    assert.ok(pid > 0);
    const messages: Record<string, unknown>[] = [];
    let parseError: Error | null = null;
    const parser = new StrictFrameParser((m) => messages.push(m));
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      reject(new Error(`footprint fragmented write test timed out for pid ${pid}`));
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
    child.stderr!.resume();
    child.stdin!.on("error", () => {});
    child.on("error", (err) => { clearTimeout(timer); reject(err); });
    child.on("close", (code, signal) => {
      clearTimeout(timer);
      if (parseError !== null) return reject(parseError);
      try {
        parser.assertCleanEof();
      } catch (err) {
        return reject(err);
      }
      resolve({ messages, code, signal, pid });
    });

    const line = Buffer.from(
      `${JSON.stringify({ path: dir, base: normalize(dir), finding: false, strict: true })}\n`,
      "utf8",
    );
    const mid = Math.floor(line.length / 2);
    // Keep stdin OPEN (production behavior): write chunks without calling stdin.end().
    child.stdin!.write(line.subarray(0, mid));
    setImmediate(() => {
      child.stdin!.write(line.subarray(mid));
    });
  });

  assert.equal(result.code, 0);
  assert.equal(result.signal, null);
  assert.equal(result.messages.length, 1);
  const msg = result.messages[0] as { size: number; complete: boolean };
  assert.equal(typeof msg.size, "number");
  assert.equal(msg.complete, true);
  assertProcessGone(result.pid);
});

test("strict frame parser and client reject unsolicited complete frames, non-JSON lines, and truncated EOF bytes", async () => {
  // 1) Parser rejects non-JSON lines and truncated/trailing bytes at EOF.
  const badLineParser = new StrictFrameParser(() => {});
  assert.throws(() => badLineParser.push(Buffer.from("not-json\n", "utf8")), /non-JSON line/);

  const trailingParser = new StrictFrameParser(() => {});
  trailingParser.push(Buffer.from('{"partial":true', "utf8"));
  assert.throws(() => trailingParser.assertCleanEof(), /trailing non-terminated bytes/);

  const truncatedBodyParser = new StrictFrameParser(() => {});
  truncatedBodyParser.push(Buffer.from('{"id":1,"bytes":10}\nabc', "utf8"));
  assert.throws(() => truncatedBodyParser.assertCleanEof(), /truncated framed body/);

  // 2) Client endAndWait() rejects when an unsolicited/unconsumed complete frame arrives before EOF,
  // and persists that error on subsequent endAndWait() calls.
  const dataDir = freshDataDir();
  const client = spawnDataReader(dataDir);
  try {
    assertReadyMessage(await client.nextMessage());
    // Trigger a complete response frame without consuming it via nextMessage().
    client.writeRaw(`${JSON.stringify({ id: 999, op: "unsolicitedTrigger", args: {} })}\n`);
    await assert.rejects(client.endAndWait(), /unexpected unsolicited frame.*999/);
    await assert.rejects(client.endAndWait(), /unexpected unsolicited frame.*999/);
    assertProcessGone(client.pid);
  } finally {
    client.kill();
  }
});
