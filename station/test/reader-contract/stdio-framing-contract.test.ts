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
import { mbReaderBinary, Said } from "../../src/read/mb-reader.ts";

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

type FramedClient = {
  child: ChildProcess;
  pid: number;
  nextMessage(): Promise<Record<string, unknown>>;
  writeRaw(chunk: string | Buffer): void;
  endAndWait(): Promise<{ code: number | null; signal: NodeJS.Signals | null }>;
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
  let closeResult: { code: number | null; signal: NodeJS.Signals | null } | null = null;
  let closeWaiters: ((res: { code: number | null; signal: NodeJS.Signals | null }) => void)[] = [];

  const said = new Said((msg) => {
    const record = msg as Record<string, unknown>;
    const waiter = waiters.shift();
    rejecters.shift();
    if (waiter) waiter(record);
    else queue.push(record);
  });

  child.stdout!.on("data", (chunk: Buffer) => said.push(chunk));
  child.stdin!.on("error", () => {});
  child.on("close", (code, signal) => {
    closed = true;
    closeResult = { code, signal };
    for (const reject of rejecters.splice(0)) {
      reject(new Error(`reader exited unexpectedly (code=${code}, signal=${signal})`));
    }
    waiters.splice(0);
    for (const resolve of closeWaiters.splice(0)) resolve(closeResult);
  });

  return {
    child,
    pid,
    nextMessage() {
      if (queue.length > 0) return Promise.resolve(queue.shift()!);
      if (closed) return Promise.reject(new Error("reader already exited"));
      return new Promise((resolve, reject) => {
        waiters.push(resolve);
        rejecters.push(reject);
      });
    },
    writeRaw(chunk: string | Buffer) {
      child.stdin!.write(chunk);
    },
    endAndWait() {
      if (closed && closeResult) return Promise.resolve(closeResult);
      return new Promise((resolve) => {
        closeWaiters.push(resolve);
        child.stdin!.end();
      });
    },
    kill() {
      if (!closed) child.kill("SIGKILL");
    },
  };
}

const nextTick = () => new Promise<void>((resolve) => setImmediate(resolve));

test("data reader: startup ready line, empty lines ignored, fragmented stdin writes, clean EOF exit", async () => {
  const dataDir = freshDataDir();
  const client = spawnDataReader(dataDir);
  try {
    // 1) Startup ready handshake
    const ready = await client.nextMessage();
    assert.ok(ready.ready && typeof ready.ready === "object", `expected ready message, got ${JSON.stringify(ready)}`);

    // 2) Blank lines are ignored and do not elicit spurious responses
    client.writeRaw("\n\n\n");

    // 3) Fragmented (half-packet) writes split mid-JSON and mid-UTF8 sequence
    const fullReq = Buffer.from(
      `${JSON.stringify({ id: 101, op: "checkpoint", args: { note: "分片测试-🚀" }, lang: "en", names: [], processes: [], clientKeys: [] })}\n`,
      "utf8",
    );
    const splitA = 17;
    const splitB = Math.floor(fullReq.length / 2);
    client.writeRaw(fullReq.subarray(0, splitA));
    await nextTick();
    client.writeRaw(fullReq.subarray(splitA, splitB));
    await nextTick();
    client.writeRaw(fullReq.subarray(splitB));

    const ans = await client.nextMessage();
    assert.equal(ans.id, 101);
    assert.ok(Buffer.isBuffer(ans.body), "checkpoint response uses bytes-framed body");
    const parsed = JSON.parse(ans.body.toString("utf8")) as Record<string, unknown>;
    assert.equal(typeof parsed.busy, "number");
    assert.equal(typeof parsed.log, "number");
    assert.equal(typeof parsed.checkpointed, "number");

    // 4) Clean exit on stdin EOF
    const exit = await client.endAndWait();
    assert.equal(exit.code, 0);
    assert.equal(exit.signal, null);
  } finally {
    client.kill();
  }
});

test("data reader: large JSON payloads (> 128 KiB) and pipelined multi-line writes", async () => {
  const dataDir = freshDataDir();
  const client = spawnDataReader(dataDir);
  try {
    const ready = await client.nextMessage();
    assert.ok("ready" in ready);

    // 256 KiB payload inside args
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

    // Write all 3 lines pipelined in one chunk
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
  } finally {
    client.kill();
  }
});

test("data reader: invalid JSON and malformed requests return structured errors without crashing", async () => {
  const dataDir = freshDataDir();
  const client = spawnDataReader(dataDir);
  try {
    const ready = await client.nextMessage();
    assert.ok("ready" in ready);

    // Malformed JSON
    client.writeRaw("{broken json\n");
    const err1 = await client.nextMessage();
    assert.equal(err1.id, null);
    assert.equal(err1.status, 400);
    assert.equal(typeof err1.error, "string");
    assert.match(err1.error as string, /^not JSON:/);

    // Valid JSON but missing op
    client.writeRaw('{"id": 301, "args": {}}\n');
    const err2 = await client.nextMessage();
    assert.deepEqual(err2, { id: 301, status: 400, error: "no op" });

    // Non-object JSON
    client.writeRaw("[1, 2, 3]\n");
    const err3 = await client.nextMessage();
    assert.deepEqual(err3, { id: null, status: 400, error: "no op" });

    // Unknown op
    client.writeRaw('{"id": 302, "op": "doesNotExist", "args": {}}\n');
    const err4 = await client.nextMessage();
    assert.deepEqual(err4, { id: 302, status: 500, error: "no read doesNotExist" });

    // Process is still healthy and answers a valid request after all errors
    client.writeRaw(`${JSON.stringify({ id: 303, op: "checkpoint", args: {}, lang: "en", names: [], processes: [], clientKeys: [] })}\n`);
    const ok = await client.nextMessage();
    assert.equal(ok.id, 303);
    assert.ok(Buffer.isBuffer(ok.body));

    const exit = await client.endAndWait();
    assert.equal(exit.code, 0);
  } finally {
    client.kill();
  }
});

test("footprint builder: fragmented stdin line reassembly and clean exit", async () => {
  const dir = mkdtempSync(join(tmpdir(), "stdio-footprint-"));
  tempDirs.push(dir);
  writeFileSync(join(dir, "hello.txt"), "hello world");

  const result = await new Promise<{ messages: unknown[]; code: number | null; signal: NodeJS.Signals | null }>((resolve, reject) => {
    const child = spawn(CANDIDATE, ["--builder", "footprint", "--sep", sep], {
      stdio: ["pipe", "pipe", "pipe"],
      windowsHide: true,
    });
    assert.ok(typeof child.pid === "number" && child.pid > 0);
    const messages: unknown[] = [];
    const said = new Said((m) => messages.push(m));
    child.stdout!.on("data", (chunk: Buffer) => said.push(chunk));
    child.stdin!.on("error", () => {});
    child.on("error", reject);
    child.on("close", (code, signal) => resolve({ messages, code, signal }));

    const line = Buffer.from(
      `${JSON.stringify({ path: dir, base: normalize(dir), finding: false, strict: true })}\n`,
      "utf8",
    );
    const mid = Math.floor(line.length / 2);
    child.stdin!.write(line.subarray(0, mid));
    setImmediate(() => {
      child.stdin!.end(line.subarray(mid));
    });
  });

  assert.equal(result.code, 0);
  assert.equal(result.signal, null);
  assert.equal(result.messages.length, 1);
  const msg = result.messages[0] as { size: number; complete: boolean };
  assert.equal(typeof msg.size, "number");
  assert.equal(msg.complete, true);
});
