// Dual-engine MB vs Pion `--data <dir> --serve <socket>` Unix-socket parity, concurrency,
// zstd streaming, write-lock contention, synthetic wall clock, and real `Served` + `front`
// engine selection verification (zero `setTimeout` sleeps).

import assert from "node:assert/strict";
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { cpSync, mkdirSync, mkdtempSync, realpathSync, rmSync } from "node:fs";
import { createConnection, type Socket } from "node:net";
import { tmpdir } from "node:os";
import { join, sep } from "node:path";
import { DatabaseSync } from "node:sqlite";
import test from "node:test";
import { createZstdDecompress, zstdDecompressSync } from "node:zlib";
import { RUNTIME_KINDS } from "../src/agents/runtime.ts";
import { withFront } from "../src/mesh/front.ts";
import { loadMesh, type Endpoint, type Stream } from "../src/mesh/native.ts";
import { SERVED_ROUTES, Served } from "../src/mesh/served.ts";
import {
  MbProcess,
  mbReaderBinary,
  pionBinary,
  resetReaderSelectionStateForTest,
  resolveReaderSelectionAsync,
} from "../src/read/mb-reader.ts";
import { READS_PENDING } from "../src/read/pool.ts";
import { Store, newMessage, LAST_KNOWN } from "../src/store/store.ts";
import { readersOf } from "./reference.ts";

const REQUIRE_DUAL = process.env.STILLFAIL_REQUIRE_DUAL_READER === "1";
const PIPE_END = 0xfffffffe;
const PIPE_FAILED = 0xfffffffd;
const PIPE_MOST = 1048576;

function resolveDualBinaries(): { mb: string; pion: string } | null {
  const mb = mbReaderBinary();
  const pion = pionBinary();
  if (!mb || !pion) {
    if (REQUIRE_DUAL) {
      assert.fail(`STILLFAIL_REQUIRE_DUAL_READER=1 requires both binaries (mb=${mb}, pion=${pion})`);
    }
    return null;
  }
  const mbReal = realpathSync(mb);
  const pionReal = realpathSync(pion);
  assert.notEqual(
    mbReal,
    pionReal,
    `MB and Pion binaries must be distinct executables (both resolved to ${mbReal})`,
  );
  return { mb: mbReal, pion: pionReal };
}

function be32(n: number): Buffer {
  const b = Buffer.alloc(4);
  b.writeUInt32BE(n >>> 0, 0);
  return b;
}

function encodeStreamHead(connId: number, streamIdx = 0): Buffer {
  const b = Buffer.alloc(25);
  b.writeBigUInt64BE(BigInt(connId), 0);
  b[16] = 2;
  b.writeBigUInt64BE(BigInt(streamIdx), 17);
  return b;
}

function encodeFrames(payload: Buffer): Buffer {
  const parts: Buffer[] = [];
  let at = 0;
  while (at < payload.length) {
    const k = Math.min(PIPE_MOST, payload.length - at);
    parts.push(be32(k), payload.subarray(at, at + k));
    at += k;
  }
  parts.push(be32(PIPE_END));
  return Buffer.concat(parts);
}

function decodeFramedResponse(raw: Buffer): { head: any; headKeys: string[]; headerKeys: string[]; body: Buffer; text: string } | null {
  if (raw.length === 0) return null;
  const chunks: Buffer[] = [];
  let at = 0;
  let sawEnd = false;
  while (at < raw.length) {
    assert.ok(at + 4 <= raw.length, `truncated frame header: rem=${raw.length - at}`);
    const n = raw.readUInt32BE(at);
    at += 4;
    if (n === PIPE_END) {
      sawEnd = true;
      break;
    }
    assert.notEqual(n, PIPE_FAILED, "unexpected PIPE_FAILED frame in response");
    assert.ok(n <= PIPE_MOST, `frame exceeds PIPE_MOST: n=${n}`);
    assert.ok(at + n <= raw.length, `truncated frame: n=${n}, rem=${raw.length - at}`);
    chunks.push(raw.subarray(at, at + n));
    at += n;
  }
  assert.ok(sawEnd, "response stream missing PIPE_END terminator");
  assert.equal(at, raw.length, `unexpected ${raw.length - at} trailing byte(s) after PIPE_END`);
  const all = Buffer.concat(chunks);
  const nl = all.indexOf(0x0a);
  assert.ok(nl >= 0, `response missing newline: ${all.toString("utf8")}`);
  const head = JSON.parse(all.subarray(0, nl).toString("utf8"));
  const body = all.subarray(nl + 1);
  const decoded =
    head.headers?.["content-encoding"] === "zstd" ? zstdDecompressSync(body) : body;
  return {
    head,
    headKeys: Object.keys(head),
    headerKeys: head.headers && typeof head.headers === "object" ? Object.keys(head.headers) : [],
    body,
    text: decoded.toString("utf8"),
  };
}

class RawServeHarness {
  readonly proc: ChildProcessWithoutNullStreams;
  readonly socket: string;
  #buf = "";
  #lines: any[] = [];
  #waiters: Array<() => void> = [];
  #closed = false;
  #stderr = "";

  constructor(binary: string, dataDir: string, socket: string) {
    this.socket = socket;
    this.proc = spawn(binary, ["--data", dataDir, "--sep", sep, "--serve", socket], {
      stdio: ["pipe", "pipe", "pipe"],
      env: { ...process.env, HOME: dataDir },
    });
    this.proc.stdout.on("data", (chunk: Buffer) => {
      this.#buf += chunk.toString("utf8");
      while (true) {
        const nl = this.#buf.indexOf("\n");
        if (nl < 0) break;
        const line = this.#buf.slice(0, nl);
        this.#buf = this.#buf.slice(nl + 1);
        if (line.length > 0) this.#lines.push(JSON.parse(line));
      }
      this.#wake();
    });
    this.proc.stderr.on("data", (chunk: Buffer) => {
      this.#stderr += chunk.toString("utf8");
    });
    this.proc.on("exit", () => {
      this.#closed = true;
      this.#wake();
    });
  }

  #wake(): void {
    const ws = this.#waiters.splice(0);
    for (const w of ws) w();
  }

  async nextMessage(pred?: (m: any) => boolean): Promise<any> {
    while (true) {
      const idx = pred ? this.#lines.findIndex(pred) : this.#lines.length > 0 ? 0 : -1;
      if (idx >= 0) {
        const [m] = this.#lines.splice(idx, 1);
        return m;
      }
      if (this.#closed) {
        throw new Error(`serve exited unexpectedly (stderr=${this.#stderr})`);
      }
      await new Promise<void>((resolve) => this.#waiters.push(resolve));
    }
  }

  drainMessages(): any[] {
    return this.#lines.splice(0);
  }

  tell(obj: unknown): void {
    this.proc.stdin.write(`${JSON.stringify(obj)}\n`);
  }

  async waitListening(): Promise<void> {
    const m = await this.nextMessage((x) => typeof x.listening === "string");
    assert.equal(m.listening, this.socket);
  }

  async sendRaw(bytes: Buffer, endAfterWrite = false): Promise<Buffer> {
    return await new Promise<Buffer>((resolve, reject) => {
      const sock = createConnection(this.socket);
      const chunks: Buffer[] = [];
      sock.on("data", (c: Buffer) => chunks.push(c));
      sock.on("end", () => resolve(Buffer.concat(chunks)));
      sock.on("error", reject);
      sock.on("connect", () => {
        if (endAfterWrite) sock.end(bytes);
        else sock.write(bytes);
      });
    });
  }

  openRequest(
    connId: number,
    head: Record<string, unknown>,
    body = "",
  ): { written: Promise<void>; response: Promise<{ head: any; headKeys: string[]; headerKeys: string[]; body: Buffer; text: string } | null> } {
    const payload = Buffer.from(`${JSON.stringify(head)}\n${body}`, "utf8");
    const wire = Buffer.concat([encodeStreamHead(connId), encodeFrames(payload)]);
    let resolveWritten!: () => void;
    const written = new Promise<void>((r) => (resolveWritten = r));
    const response = new Promise<Buffer>((resolve, reject) => {
      const sock = createConnection(this.socket);
      const chunks: Buffer[] = [];
      sock.on("data", (c: Buffer) => chunks.push(c));
      sock.on("end", () => resolve(Buffer.concat(chunks)));
      sock.on("error", reject);
      sock.on("connect", () => {
        sock.write(wire, () => resolveWritten());
      });
    }).then(decodeFramedResponse);
    return { written, response };
  }

  async request(
    connId: number,
    head: Record<string, unknown>,
    body = "",
  ): Promise<{ head: any; headKeys: string[]; headerKeys: string[]; body: Buffer; text: string } | null> {
    return await this.openRequest(connId, head, body).response;
  }

  openStream(connId: number, head: Record<string, unknown>, body = ""): Socket {
    const sock = createConnection(this.socket);
    const payload = Buffer.from(`${JSON.stringify(head)}\n${body}`, "utf8");
    const wire = Buffer.concat([encodeStreamHead(connId), encodeFrames(payload)]);
    sock.on("connect", () => {
      sock.write(wire);
    });
    return sock;
  }

  async close(): Promise<number> {
    if (!this.#closed) {
      this.proc.stdin.end();
      await new Promise<void>((resolve) => {
        if (this.#closed) resolve();
        else this.proc.once("exit", () => resolve());
      });
    }
    return this.proc.exitCode ?? 0;
  }
}

function buildFixture(dir: string): {
  thread: number;
  hiddenThread: number;
  wentThread: number;
  slackThread: number;
  cardThread: number;
  cardN: number;
  agentN: number;
  loneOptN: number;
} {
  mkdirSync(dir, { recursive: true });
  const store = Store.open(join(dir, "stillfail.db"), join(dir, "archive"));
  try {
    for (let k = 0; k < 5; k++) {
      store.insertSession({
        key: `s${k}`,
        connect: "ember",
        runtime: "claude",
        profile: "cc",
        workspace: "/w",
        token: `s${k}`,
        createdAt: 1,
        lastActiveAt: 1000 + k,
      } as Parameters<Store["insertSession"]>[0]);
      const t = store.openThreadOf("ember", "CHAT", `c${k}`, `Chat ${k}`, null, `s${k}`).id;
      store.joinThread(t, `s${k}`, "ember");
      store.insertMessage({
        ...newMessage(t, `${k + 1}.000001`, "person", "Alice@Example.com", `hello ${k} ${"word ".repeat(35)}`),
        at: 100 + k,
      } as ReturnType<typeof newMessage>);
    }
    store.insertSession({
      key: "elsewhere",
      connect: "ember",
      runtime: "claude",
      profile: "cc",
      workspace: "/w",
      token: "e",
      createdAt: 1,
      lastActiveAt: 1,
      ws: "other",
    } as Parameters<Store["insertSession"]>[0]);
    const hiddenThread = store.openThread("ember", "CHAT", "ce", "Elsewhere", null).id;
    store.joinThread(hiddenThread, "elsewhere", "ember");

    store.insertSession({
      key: "gone",
      connect: "ember",
      runtime: "claude",
      profile: "cc",
      workspace: "/w",
      token: "g",
      createdAt: 1,
      lastActiveAt: 1,
      ws: "handed:ws",
    } as Parameters<Store["insertSession"]>[0]);
    const wentThread = store.openThread("ember", "CHAT", "cg", "Gone", null).id;
    store.joinThread(wentThread, "gone", "ember");
    store.db
      .prepare("INSERT INTO handed_over (session, station, ws, thread, there, at) VALUES ('gone', 'stC', 'ws', ?, 9, 1)")
      .run(wentThread);

    const thread = store.openThread("ember", "CHAT", "main", "Main Chat", null).id;
    for (let i = 0; i < 12; i++) {
      store.insertMessage({
        ...newMessage(thread, `${10 + i}.000001`, "person", "Alice@Example.com", `msg ${i} ${"payload ".repeat(20)}`),
        at: (i + 1) * 10,
      } as ReturnType<typeof newMessage>);
    }
    const [agentN] = store.insertMessage({
      ...newMessage(thread, "99.000001", "agent", "s0", "agent asks"),
      at: 999,
    } as ReturnType<typeof newMessage>);

    // Legacy non-agent entry with card = NULL and `options` containing an unpaired UTF-16 surrogate
    const [loneOptN] = store.insertMessage({
      ...newMessage(thread, "100.000001", "person", "Alice@Example.com", "legacy opt"),
      at: 1000,
    } as ReturnType<typeof newMessage>);
    store.db
      .prepare("UPDATE entries SET card = NULL, options = ? WHERE thread = ? AND n = ?")
      .run('{"items":["bad\\ud800opt"]}', thread, loneOptN);

    const slackThread = store.openThread("slack", "C1", "1.0", "Slack", null).id;

    const cardThread = store.openThread("ember", "CHAT", "card", "Card Chat", null).id;
    const [cardN] = store.insertMessage({
      ...newMessage(cardThread, "5.000001", "agent", "s0", "choose"),
      card: { type: "options", options: [{ label: "CloseIt", action: "close" }, { label: "ReplyIt" }] },
      at: 50,
    } as ReturnType<typeof newMessage>);

    return { thread, hiddenThread, wentThread, slackThread, cardThread, cardN, agentN, loneOptN };
  } finally {
    store.close();
  }
}

const DEFAULT_SET = {
  lastKnown: LAST_KNOWN,
  words: {
    en: {
      updateApp: "Please update",
      badN: "bad n",
      postOnlyStillfail: "stillfail only",
      emptyMessage: "empty message",
      renameOnlyStillfail: "rename stillfail only",
      nothingWaiting: "nothing waiting",
      updateClientForOption: "update client for option",
      movedThere: "moved there",
    },
    zh: {
      updateApp: "请更新",
      badN: "无效 n",
      postOnlyStillfail: "仅限站内对话",
      emptyMessage: "空消息",
      renameOnlyStillfail: "仅限站内改名",
      nothingWaiting: "无等待项",
      updateClientForOption: "请更新客户端",
      movedThere: "已迁走",
    },
  },
  oldestCore: 5000,
  countedFrom: 1000,
  movedFromBuild: 9000,
  build: "0.1.9500",
  runtimes: [...RUNTIME_KINDS],
  pending: [...READS_PENDING],
};

const BASE_VIEWER = { email: "Alice@Example.com", name: "Alice", workspace: "ws", role: "owner", home: true };

const BASE_HEADERS = {
  "stillfail-build": "0.1.9500",
  "stillfail-runtimes": RUNTIME_KINDS.join(","),
  "accept-encoding": "zstd",
  "stillfail-lang": "en",
};

test("Dual-engine MB vs Pion `--serve`: framing, viewer gating, local reads, batch, Refused pending, zstd, marks, say, relay, wall clock, and write-lock contention", async (t) => {
  const bins = resolveDualBinaries();
  if (!bins) {
    t.skip("dual reader binaries unavailable");
    return;
  }

  // Negative self-checks for strict `decodeFramedResponse` (missing PIPE_END, trailing garbage, over-long frame)
  const samplePayload = Buffer.from('{"status":200,"headers":{}}\n{}', "utf8");
  assert.throws(
    () => decodeFramedResponse(Buffer.concat([be32(samplePayload.length), samplePayload])),
    /missing PIPE_END/,
  );
  assert.throws(
    () => decodeFramedResponse(Buffer.concat([be32(samplePayload.length), samplePayload, be32(PIPE_END), Buffer.from([0x42])])),
    /trailing byte/,
  );
  assert.throws(
    () => decodeFramedResponse(Buffer.concat([be32(PIPE_MOST + 1), be32(PIPE_END)])),
    /exceeds PIPE_MOST/,
  );

  const root = mkdtempSync(join(tmpdir(), "w7g-serve-parity-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const baseData = join(root, "base");
  const fix = buildFixture(baseData);
  // Prepare read-index tables once on baseData (same as production pool) so local reads answer directly
  const prepPool = readersOf(baseData, bins.mb);
  try {
    await prepPool.read("sessions", { connect: null, archived: false, lang: "en", viewer: BASE_VIEWER }, "en").catch(() => {});
    await prepPool.read("threads", { viewer: BASE_VIEWER, session: null, lang: "en" }, "en").catch(() => {});
    await prepPool.read("entries", { viewer: BASE_VIEWER, thread: fix.thread, params: [] }, "en").catch(() => {});
    await prepPool.read("sharedChats", { viewer: BASE_VIEWER, sessions: null, threads: null }, "en").catch(() => {});
  } finally {
    await prepPool.close();
  }

  const runSuiteOn = async (label: string, binary: string) => {
    const dataDir = join(root, `data-${label}`);
    cpSync(baseData, dataDir, { recursive: true });
    const sock = join(root, `serve-${label}.sock`);
    const srv = new RawServeHarness(binary, dataDir, sock);
    t.after(() => {
      if (srv.proc.exitCode === null) srv.proc.kill("SIGKILL");
    });
    try {
      await srv.waitListening();
      srv.tell({ set: DEFAULT_SET, wall: 1750000000000 });
      srv.tell({ names: [["Alice@Example.com", "Alice"]] });
      srv.tell({ viewer: { conn: 20, viewer: BASE_VIEWER, moved: false, floor: null }, wall: 1750000005000 });
      const syncBarrier = async () => {
        const probe = (await srv.request(20, { method: "GET", path: "/admin/api/jobs/none", headers: BASE_HEADERS }))!;
        assert.equal(probe.head.status, 404);
      };
      // Deterministic stdin-to-socket + stdout fence: a fresh conn ID cannot be answered until its viewer line
      // (and therefore every earlier stdin line) has been processed. Omitting `stillfail-build` causes both MB
      // (`serve.mbt:410`) and Pion (`serve.pion:1170`) to emit `{"build":{"conn":cid,"build":null}}` on stdout,
      // so awaiting that `build` line also drains every prior stdout message (`changes`/`titled`) deterministically.
      let fenceConn = 1000;
      const flushStdin = async () => {
        const cid = fenceConn++;
        srv.tell({ viewer: { conn: cid, viewer: BASE_VIEWER, moved: false, floor: null } });
        const probe = (await srv.request(cid, {
          method: "GET",
          path: "/admin/api/sessions/__stdin_fence__",
          headers: { "stillfail-lang": "en", "stillfail-runtimes": RUNTIME_KINDS.join(",") },
        }))!;
        assert.equal(probe.head.status, 404);
        const buildFence = await srv.nextMessage((m) => m.build?.conn === cid);
        assert.deepEqual(buildFence, { build: { conn: cid, build: null } });
      };

      // 1. Raw BE32 framing edge cases: over-long u32, PIPE_FAILED, half-close EOF, missing newline, bad JSON -> silent close (0 bytes)
      const overLong = await srv.sendRaw(Buffer.concat([encodeStreamHead(1), be32(PIPE_MOST + 1)]));
      assert.equal(overLong.length, 0, `${label}: over-long frame must close silently`);

      const pipeFailed = await srv.sendRaw(Buffer.concat([encodeStreamHead(1), be32(PIPE_FAILED)]));
      assert.equal(pipeFailed.length, 0, `${label}: PIPE_FAILED must close silently`);

      const halfClose = await srv.sendRaw(encodeStreamHead(1).subarray(0, 10), true);
      assert.equal(halfClose.length, 0, `${label}: half-close EOF must close silently`);

      const noNewline = await srv.sendRaw(
        Buffer.concat([encodeStreamHead(1), encodeFrames(Buffer.from("no-newline-here"))]),
      );
      assert.equal(noNewline.length, 0, `${label}: missing newline must close silently`);

      const badJson = await srv.sendRaw(
        Buffer.concat([encodeStreamHead(1), encodeFrames(Buffer.from("{bad-json\n"))]),
      );
      assert.equal(badJson.length, 0, `${label}: bad JSON head must close silently`);

      // 2. Viewer grant -> request 200 -> single-shot viewer: null revocation clears cached viewer
      // (deterministic single-shot revocation of a stream in PHASE_WAIT_VIEWER is covered in `selftest.pion`)
      srv.tell({ viewer: { conn: 10, viewer: BASE_VIEWER, moved: false, floor: null } });
      const granted10 = (await srv.request(10, { method: "GET", path: "/admin/api/sessions", headers: BASE_HEADERS }))!;
      assert.equal(granted10.head.status, 200);
      const build10 = await srv.nextMessage((m) => m.build?.conn === 10);
      assert.deepEqual(build10.build, { conn: 10, build: 9500 });
      srv.tell({ viewer: { conn: 10, viewer: null } });
      await flushStdin();

      // 3. Viewer wait -> arrive with floor gating (426) vs allowed (200) + moved fallback without floor
      const waitFloor = srv.openRequest(11, {
        method: "GET",
        path: "/admin/api/sessions",
        headers: { ...BASE_HEADERS, "stillfail-build": "0.1.9199" },
      });
      await waitFloor.written;
      await syncBarrier();
      srv.tell({ viewer: { conn: 11, viewer: BASE_VIEWER, moved: true, floor: 9200 }, wall: 1750000001000 });
      const floor426 = (await waitFloor.response)!;
      assert.equal(floor426.head.status, 426);
      assert.deepEqual(JSON.parse(floor426.text), { error: "Please update", update: true });

      const floorOk = (await srv.request(11, {
        method: "GET",
        path: "/admin/api/sessions",
        headers: { ...BASE_HEADERS, "stillfail-build": "0.1.9200" },
      }))!;
      assert.equal(floorOk.head.status, 200);
      const buildMsg = await srv.nextMessage((m) => m.build !== undefined && m.build.conn === 11);
      assert.deepEqual(buildMsg.build, { conn: 11, build: 9200 });

      // Moved without floor -> uses movedFromBuild (9000)
      srv.tell({ viewer: { conn: 12, viewer: BASE_VIEWER, moved: true } });
      const moved426 = (await srv.request(12, {
        method: "GET",
        path: "/admin/api/sessions",
        headers: { ...BASE_HEADERS, "stillfail-build": "0.1.8999" },
      }))!;
      assert.equal(moved426.head.status, 426);

      // 4. Local reads, zstd <512 uncompressed vs >=512 compressed, changed, batch, and unseen 404/409
      srv.tell({ viewer: { conn: 20, viewer: BASE_VIEWER, moved: false, floor: null }, wall: 1750000005000 });
      await flushStdin();

      const smallRead = (await srv.request(20, {
        method: "GET",
        path: "/admin/api/jobs/none",
        headers: BASE_HEADERS,
      }))!;
      assert.equal(smallRead.head.status, 404);
      assert.equal(smallRead.head.headers["content-encoding"], undefined, `${label}: <512 bytes must not be zstd`);
      assert.equal(smallRead.head.headers["content-length"], String(smallRead.body.length));

      const bigRead = (await srv.request(20, {
        method: "GET",
        path: `/admin/api/threads/${fix.thread}/entries`,
        headers: BASE_HEADERS,
      }))!;
      assert.equal(bigRead.head.status, 200);
      assert.equal(bigRead.head.headers["content-encoding"], "zstd", `${label}: >=512 bytes must be zstd`);
      assert.equal(bigRead.head.headers["stillfail-idempotent"], "1");
      assert.equal(bigRead.head.headers["stillfail-build"], "0.1.9500");

      const changedSessions = (await srv.request(
        20,
        { method: "POST", path: "/admin/api/changed/sessions", headers: BASE_HEADERS },
        JSON.stringify({ held: { s0: "stale" } }),
      ))!;
      assert.equal(changedSessions.head.status, 200);

      const batchOk = (await srv.request(
        20,
        { method: "POST", path: "/admin/api/batch", headers: BASE_HEADERS },
        JSON.stringify({ gets: [`/threads/${fix.thread}`, "/sessions/s0", "/chats"] }),
      ))!;
      assert.equal(batchOk.head.status, 200);
      const batchParsed = JSON.parse(batchOk.text);
      assert.equal(batchParsed.answers.length, 3);
      assert.equal(batchParsed.answers[0].status, 200);
      assert.equal(batchParsed.answers[1].status, 200);
      assert.equal(batchParsed.answers[2].status, 400);

      const unseenRead = (await srv.request(20, {
        method: "GET",
        path: `/admin/api/threads/${fix.hiddenThread}`,
        headers: BASE_HEADERS,
      }))!;
      assert.equal(unseenRead.head.status, 404);

      const wentWrite = (await srv.request(
        20,
        { method: "PUT", path: `/admin/api/threads/${fix.wentThread}/read`, headers: BASE_HEADERS },
        JSON.stringify({ n: 1 }),
      ))!;
      assert.equal(wentWrite.head.status, 409);

      // 5. Refused pending fallback vs direct status (custom pending prefix)
      srv.tell({ set: { ...DEFAULT_SET, pending: ["no job "] } });
      await flushStdin();
      const pendingFbP = srv.request(20, {
        method: "GET",
        path: "/admin/api/jobs/missing-job",
        headers: BASE_HEADERS,
      });
      const fbMsg = await srv.nextMessage((m) => typeof m.fallback === "number" && m.head?.path === "/admin/api/jobs/missing-job");
      srv.tell({
        answered: fbMsg.fallback,
        status: 200,
        headers: { "content-type": "application/json" },
        text: JSON.stringify({ fromFallback: true }),
      });
      const pendingFbRes = (await pendingFbP)!;
      assert.equal(pendingFbRes.head.status, 200);
      assert.deepEqual(JSON.parse(pendingFbRes.text), { fromFallback: true });
      // Restore default pending -> direct 404 without fallback
      srv.tell({ set: DEFAULT_SET });
      await flushStdin();
      const direct404 = (await srv.request(20, {
        method: "GET",
        path: "/admin/api/jobs/missing-job",
        headers: BASE_HEADERS,
      }))!;
      assert.equal(direct404.head.status, 404);

      // 6. Concurrent interleaved fallback + 2 zstd relay streams (distinct query tags) + `pieces: { pieces, to }` broadcast + write-failure `stop`
      const rSock1 = srv.openStream(20, { method: "GET", path: "/admin/api/events?shared=1&tag=r1", headers: BASE_HEADERS });
      const rSock2 = srv.openStream(20, { method: "GET", path: "/admin/api/events?shared=1&tag=r2", headers: BASE_HEADERS });
      const fbInterleavedP = srv.request(20, {
        method: "GET",
        path: "/admin/api/chats",
        headers: { ...BASE_HEADERS, "stillfail-runtimes": "claude" },
      });

      const [relReq1, relReq2, fbInterleavedReq] = await Promise.all([
        srv.nextMessage((m) => typeof m.fallback === "number" && m.stream === true && m.head?.path === "/admin/api/events?shared=1&tag=r1"),
        srv.nextMessage((m) => typeof m.fallback === "number" && m.stream === true && m.head?.path === "/admin/api/events?shared=1&tag=r2"),
        srv.nextMessage((m) => typeof m.fallback === "number" && m.stream !== true && m.head?.path === "/admin/api/chats"),
      ]);

      const attachRelayReader = (sock: Socket) => {
        let raw = Buffer.alloc(0);
        let head: any = null;
        let seen = "";
        const waiters: Array<() => void> = [];
        const wake = () => {
          for (const w of waiters.splice(0)) w();
        };
        const z = createZstdDecompress();
        z.on("data", (d: Buffer) => {
          seen += d.toString("utf8");
          wake();
        });
        sock.on("data", (c: Buffer) => {
          raw = Buffer.concat([raw, c]);
          while (raw.length >= 4) {
            const n = raw.readUInt32BE(0);
            if (n === PIPE_END) {
              raw = raw.subarray(4);
              wake();
              break;
            }
            if (raw.length < 4 + n) break;
            const frame = raw.subarray(4, 4 + n);
            raw = raw.subarray(4 + n);
            if (head === null) {
              const nl = frame.indexOf(0x0a);
              head = JSON.parse(frame.subarray(0, nl).toString("utf8"));
              if (nl + 1 < frame.length) z.write(frame.subarray(nl + 1), wake);
              else wake();
            } else {
              z.write(frame, wake);
            }
          }
        });
        const waitFor = async (substr: string) => {
          while (!seen.includes(substr)) {
            await new Promise<void>((r) => waiters.push(r));
          }
          return { head, seen };
        };
        return { waitFor, close: () => sock.destroy() };
      };

      const rr1 = attachRelayReader(rSock1);
      const rr2 = attachRelayReader(rSock2);

      // Answer interleaved fallback with >=512 bytes JSON to verify fallback zstd compression
      const bigFallbackText = JSON.stringify({ fallbackPayload: "x".repeat(600) });
      srv.tell({
        answered: fbInterleavedReq.fallback,
        status: 200,
        headers: { "content-type": "application/json" },
        text: bigFallbackText,
      });
      const fbInterleavedRes = (await fbInterleavedP)!;
      assert.equal(fbInterleavedRes.head.status, 200);
      assert.equal(fbInterleavedRes.head.headers["content-encoding"], "zstd");
      assert.equal(fbInterleavedRes.text, bigFallbackText);

      // Answer both relays and broadcast a single `pieces` message to both
      srv.tell({ answered: relReq1.fallback, status: 200, headers: { "content-type": "text/event-stream" } });
      srv.tell({ answered: relReq2.fallback, status: 200, headers: { "content-type": "text/event-stream" } });
      srv.tell({ pieces: "event: ping\ndata: broadcast-1\n\n", to: [relReq1.fallback, relReq2.fallback] });

      const got1 = await rr1.waitFor("broadcast-1");
      const got2 = await rr2.waitFor("broadcast-1");
      assert.equal(got1.head.headers["content-encoding"], "zstd");
      assert.equal(got2.head.headers["content-encoding"], "zstd");

      // Cleanly finish relay 1
      srv.tell({ done: relReq1.fallback });
      // Destroy relay 2 socket and push chunks until server detects write failure and emits `stop`
      rr2.close();
      let stopped = false;
      const stopPromise = srv.nextMessage((m) => m.stop === relReq2.fallback).then(() => {
        stopped = true;
      });
      for (let i = 0; i < 64 && !stopped; i++) {
        srv.tell({ chunk: relReq2.fallback, text: `event: push\ndata: ${"z".repeat(4096)}-${i}\n\n` });
        await syncBarrier();
      }
      await stopPromise;
      rr1.close();

      // 7. Marks (read, hidden, muted lowercase, keep, pin, dismissed, title with 80 emoji code points) + synthetic wall clock
      const emoji85 = `  ${"😀".repeat(85)} `;
      const emoji80 = "😀".repeat(80);
      const sessTitle = (await srv.request(
        20,
        { method: "POST", path: "/admin/api/sessions/s0/title", headers: BASE_HEADERS },
        JSON.stringify({ title: emoji85 }),
      ))!;
      assert.equal(sessTitle.head.status, 200);

      const threadTitle = (await srv.request(
        20,
        { method: "PUT", path: `/admin/api/threads/${fix.thread}/title`, headers: BASE_HEADERS },
        JSON.stringify({ title: emoji85 }),
      ))!;
      assert.equal(threadTitle.head.status, 200);
      assert.equal(JSON.parse(threadTitle.text).title, emoji80);

      // Lone UTF-16 surrogate in authorized write JSON must be strictly rejected with 400 (DB title untouched)
      const loneSurrogateTitle = (await srv.request(
        20,
        { method: "PUT", path: `/admin/api/threads/${fix.thread}/title`, headers: BASE_HEADERS },
        '{"title":"bad\\ud800title"}',
      ))!;
      assert.equal(loneSurrogateTitle.head.status, 400, `${label}: lone surrogate JSON must return 400`);

      const slackTitleErr = (await srv.request(
        20,
        { method: "PUT", path: `/admin/api/threads/${fix.slackThread}/title`, headers: BASE_HEADERS },
        JSON.stringify({ title: "nope" }),
      ))!;
      assert.equal(slackTitleErr.head.status, 400);

      const readMark = (await srv.request(
        20,
        { method: "PUT", path: `/admin/api/threads/${fix.thread}/read`, headers: BASE_HEADERS },
        JSON.stringify({ n: 5 }),
      ))!;
      assert.equal(readMark.head.status, 200);

      const mutedMark = (await srv.request(
        20,
        { method: "PUT", path: `/admin/api/threads/${fix.thread}/muted`, headers: BASE_HEADERS },
        JSON.stringify({ muted: true }),
      ))!;
      assert.equal(mutedMark.head.status, 200);

      const pinMark = (await srv.request(20, {
        method: "PUT",
        path: "/admin/api/sessions/s0/pin",
        headers: BASE_HEADERS,
      }))!;
      assert.equal(pinMark.head.status, 200);

      const dismissMark = (await srv.request(
        20,
        { method: "PUT", path: `/admin/api/threads/${fix.thread}/dismissed`, headers: BASE_HEADERS },
        JSON.stringify({ n: fix.agentN }),
      ))!;
      assert.equal(dismissMark.head.status, 200);

      // Legacy non-agent entry with card = NULL and `options` containing an unpaired UTF-16 surrogate:
      // both MB (`serve.mbt:1400`) and Pion (`parsed_column` -> `parse_json_strict`) must return 404 without inserting into `dismissed`.
      const dismissLoneOpt = (await srv.request(
        20,
        { method: "PUT", path: `/admin/api/threads/${fix.thread}/dismissed`, headers: BASE_HEADERS },
        JSON.stringify({ n: fix.loneOptN }),
      ))!;
      assert.equal(dismissLoneOpt.head.status, 404, `${label}: legacy options with lone surrogate must return 404 on dismiss`);

      // 8. Person's message (`claim` / `said` + quotes + card close 409 + card reply read advance)
      const cardClose409 = (await srv.request(
        20,
        { method: "POST", path: `/admin/api/threads/${fix.cardThread}/messages`, headers: BASE_HEADERS },
        JSON.stringify({ text: "CloseIt", quotes: [{ author: "s0", text: "choose", ts: "5.000001" }] }),
      ))!;
      assert.equal(cardClose409.head.status, 409);

      const sayP = srv.request(
        20,
        {
          method: "POST",
          path: `/admin/api/threads/${fix.cardThread}/messages`,
          headers: { ...BASE_HEADERS, "idempotency-key": "k-card-1" },
        },
        JSON.stringify({
          text: "  ReplyIt  ",
          client: "desktop 0.1.9500\u0007",
          quotes: [{ author: "s0", text: "choose", ts: "5.000001", role: "agent" }],
        }),
      );
      const claimMsg = await srv.nextMessage((m) => typeof m.claim === "number");
      assert.equal(claimMsg.key, "k-card-1");

      srv.tell({ claimed: claimMsg.claim, ts: "1750000010.000001" });

      const sayRes = (await sayP)!;
      assert.equal(sayRes.head.status, 200);
      const saidMsg = await srv.nextMessage((m) => m.said !== undefined && m.of === claimMsg.claim);
      assert.equal(saidMsg.said.thread, fix.cardThread);
      assert.equal(saidMsg.said.text, "ReplyIt");
      assert.equal(saidMsg.said.row.client, "desktop 0.1.9500");

      // Deterministic stdout fence: flushes all prior `changes`/`titled` lines on stdout before draining
      await flushStdin();
      const extraStdout = srv.drainMessages();

      // Inspect persisted DB state (muted_chats lowercased, synthetic wall >= 1750000005000, card read advanced, title intact)
      const checkDb = new DatabaseSync(join(dataDir, "stillfail.db"), { open: true });
      try {
        const mutedRows = checkDb.prepare("SELECT viewer FROM muted_chats WHERE thread = ?").all(fix.thread) as {
          viewer: string;
        }[];
        assert.deepEqual(
          mutedRows.map((r) => r.viewer),
          ["alice@example.com"],
          `${label}: muted_chats must store lowercased email`,
        );
        const readRow = checkDb
          .prepare("SELECT n, at FROM reads WHERE viewer = ? AND thread = ?")
          .get("Alice@Example.com", fix.thread) as { n: number; at: number };
        assert.equal(readRow.n, 5);
        assert.ok(readRow.at >= 1750000005000, `${label}: reads.at must reflect synthetic wall clock`);

        const cardRead = checkDb
          .prepare("SELECT n FROM reads WHERE viewer = ? AND thread = ?")
          .get("Alice@Example.com", fix.cardThread) as { n: number };
        assert.equal(cardRead.n, fix.cardN);

        const sessRow = checkDb.prepare("SELECT title FROM sessions WHERE key = 's0'").get() as { title: string };
        assert.equal(sessRow.title, emoji80);
        const threadRow = checkDb.prepare("SELECT title FROM threads WHERE id = ?").get(fix.thread) as { title: string };
        assert.equal(threadRow.title, emoji80, `${label}: lone surrogate write must leave DB title unchanged`);
        const dismissedRows = checkDb
          .prepare("SELECT n FROM dismissed WHERE thread = ? ORDER BY n")
          .all(fix.thread) as { n: number }[];
        assert.deepEqual(
          dismissedRows.map((r) => r.n),
          [fix.agentN],
          `${label}: dismiss on legacy lone-surrogate options must not insert into dismissed table`,
        );

        const respSnap = (r: { head: any; headKeys: string[]; headerKeys: string[]; text: string }) => ({
          head: r.head,
          headKeys: r.headKeys,
          headerKeys: r.headerKeys,
          body: JSON.parse(r.text),
        });
        const normFallback = (m: any) => ({ conn: m.conn, head: m.head, body: m.body, stream: m.stream });

        const normExtra = extraStdout.map((msg) => {
          if (!Array.isArray(msg?.changes)) return msg;
          return {
            ...msg,
            changes: msg.changes.map((c: any) => {
              if (c?.type === "pins" && typeof c.at === "number") {
                assert.ok(c.at >= 1750000005000, `${label}: pins change at must reflect synthetic wall clock`);
                return { ...c, at: "<wall>" };
              }
              return c;
            }),
          };
        });

        return {
          smallRead: respSnap(smallRead),
          bigRead: respSnap(bigRead),
          changedSessions: respSnap(changedSessions),
          batchOk: respSnap(batchOk),
          unseenRead: respSnap(unseenRead),
          wentWrite: respSnap(wentWrite),
          pendingFbRes: respSnap(pendingFbRes),
          direct404: respSnap(direct404),
          fbInterleavedRes: respSnap(fbInterleavedRes),
          relay1: { head: got1.head, headKeys: Object.keys(got1.head), seen: got1.seen },
          relay2: { head: got2.head, headKeys: Object.keys(got2.head), seen: got2.seen },
          sessTitle: respSnap(sessTitle),
          threadTitle: respSnap(threadTitle),
          loneSurrogateTitle: respSnap(loneSurrogateTitle),
          slackTitleErr: respSnap(slackTitleErr),
          readMark: respSnap(readMark),
          mutedMark: respSnap(mutedMark),
          pinMark: respSnap(pinMark),
          dismissMark: respSnap(dismissMark),
          dismissLoneOpt: respSnap(dismissLoneOpt),
          cardClose409: respSnap(cardClose409),
          sayRes: respSnap(sayRes),
          protocol: {
            buildMsg,
            fbMsg: normFallback(fbMsg),
            fbInterleavedReq: normFallback(fbInterleavedReq),
            relReq1: normFallback(relReq1),
            relReq2: normFallback(relReq2),
            claimMsg: { path: claimMsg.path, key: claimMsg.key, lang: claimMsg.lang, conn: claimMsg.conn },
            saidMsg: { said: saidMsg.said, answer: saidMsg.answer },
            extraStdout: normExtra,
          },
        };
      } finally {
        checkDb.close();
      }
    } finally {
      await srv.close();
    }
  };

  const mbOut = await runSuiteOn("mb", bins.mb);
  const pionOut = await runSuiteOn("pion", bins.pion);
  assert.deepEqual(pionOut, mbOut, "Pion --serve must match MoonBit --serve byte/JSON-for-JSON");
});

test("Real Served integration: STILLFAIL_READER_SERVE=pion spawns BIN_PION (verified via MbProcess.live()) and answers requests", async (t) => {
  const bins = resolveDualBinaries();
  if (!bins) {
    t.skip("dual reader binaries unavailable");
    return;
  }

  // Negative self-checks for strict `decodeFramedResponse` (missing PIPE_END, trailing garbage, over-long frame)
  const samplePayload = Buffer.from('{"status":200,"headers":{}}\n{}', "utf8");
  assert.throws(
    () => decodeFramedResponse(Buffer.concat([be32(samplePayload.length), samplePayload])),
    /missing PIPE_END/,
  );
  assert.throws(
    () => decodeFramedResponse(Buffer.concat([be32(samplePayload.length), samplePayload, be32(PIPE_END), Buffer.from([0x42])])),
    /trailing byte/,
  );
  assert.throws(
    () => decodeFramedResponse(Buffer.concat([be32(PIPE_MOST + 1), be32(PIPE_END)])),
    /exceeds PIPE_MOST/,
  );

  const dir = mkdtempSync(join(tmpdir(), "w7g-served-live-"));
  const dataDir = join(dir, "data");
  buildFixture(dataDir);

  const prevEnv = {
    STILLFAIL_READER_SERVE: process.env.STILLFAIL_READER_SERVE,
    STILLFAIL_READER_ENGINE: process.env.STILLFAIL_READER_ENGINE,
    STILLFAIL_MB_READER: process.env.STILLFAIL_MB_READER,
    STILLFAIL_PION_READER: process.env.STILLFAIL_PION_READER,
  };
  t.after(() => {
    for (const [k, v] of Object.entries(prevEnv)) {
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
    resetReaderSelectionStateForTest();
  });

  // 1. Verify default (no override) selects MB, and STILLFAIL_READER_SERVE=pion selects Pion
  delete process.env.STILLFAIL_READER_SERVE;
  delete process.env.STILLFAIL_READER_ENGINE;
  process.env.STILLFAIL_MB_READER = bins.mb;
  process.env.STILLFAIL_PION_READER = bins.pion;
  resetReaderSelectionStateForTest();

  const defaultSel = await resolveReaderSelectionAsync("serve");
  assert.equal(defaultSel.engine, "mb");
  assert.equal(realpathSync(defaultSel.primaryBinary), bins.mb);

  process.env.STILLFAIL_READER_SERVE = "pion";
  resetReaderSelectionStateForTest();
  const pionSel = await resolveReaderSelectionAsync("serve");
  assert.equal(pionSel.engine, "pion");
  assert.equal(realpathSync(pionSel.primaryBinary), bins.pion);

  // 2. Start real `Served` using `pionSel.primaryBinary` (verified via MbProcess.live())
  const fallbackHits: string[] = [];
  const served = new Served(
    pionSel.primaryBinary,
    dataDir,
    async (_v, head) => {
      fallbackHits.push(head.path);
      return { status: 200, headers: { "content-type": "application/json" }, body: Buffer.from('{"fallback":true}') };
    },
    () => {},
  );
  let station: Endpoint | null = null;
  let device: Endpoint | null = null;
  let frontProc: MbProcess | null = null;
  t.after(async () => {
    await served.close();
    if (device) await device.close();
    if (station) await station.close();
    if (frontProc) await frontProc.terminate();
    rmSync(dir, { recursive: true, force: true });
  });

  const paths = await served.start();
  assert.equal(paths.length, 2);

  // Assert via MbProcess.live() that every `--serve` process is genuinely BIN_PION!
  const liveServe = MbProcess.live().filter((p) => p.args.includes("--serve") && p.args.includes(dataDir));
  assert.equal(liveServe.length, 2, "expected 2 live --serve processes");
  for (const proc of liveServe) {
    assert.equal(
      realpathSync(proc.binary),
      bins.pion,
      `expected live --serve binary to be BIN_PION (${bins.pion}), got ${proc.binary}`,
    );
  }

  // 3. Send real framed requests directly over the Served Unix socket (works with or without mesh.node)
  served.viewer(42, BASE_VIEWER);
  const sendFramed = async (sockPath: string, connId: number, head: Record<string, unknown>) => {
    const payload = Buffer.from(`${JSON.stringify(head)}\n`, "utf8");
    const wire = Buffer.concat([encodeStreamHead(connId), encodeFrames(payload)]);
    const raw = await new Promise<Buffer>((resolve, reject) => {
      const sock = createConnection(sockPath);
      const chunks: Buffer[] = [];
      sock.on("data", (c: Buffer) => chunks.push(c));
      sock.on("end", () => resolve(Buffer.concat(chunks)));
      sock.on("error", reject);
      sock.on("connect", () => sock.write(wire));
    });
    return decodeFramedResponse(raw)!;
  };

  const directSessions = await sendFramed(paths[0], 42, {
    method: "GET",
    path: "/admin/api/sessions",
    headers: BASE_HEADERS,
  });
  assert.equal(directSessions.head.status, 200);
  const parsedSessions = JSON.parse(directSessions.text);
  assert.ok(Array.isArray(parsedSessions) && parsedSessions.length >= 5, "expected Pion --serve to return sessions list");

  // Also verify fallback routing through real `Served` when client lacks a runtime
  const fallbackRes = await sendFramed(paths[1], 42, {
    method: "GET",
    path: "/admin/api/chats",
    headers: { ...BASE_HEADERS, "stillfail-runtimes": "claude" },
  });
  assert.equal(fallbackRes.head.status, 200);
  assert.deepEqual(JSON.parse(fallbackRes.text), { fallback: true });
  assert.deepEqual(fallbackHits, ["/admin/api/chats"]);

  // 4. Verify end-to-end iroh -> front -> Pion --serve (mandatory when STILLFAIL_REQUIRE_DUAL_READER=1)
  let meshNative: ReturnType<typeof loadMesh> | null = null;
  try {
    meshNative = loadMesh();
  } catch (err) {
    if (REQUIRE_DUAL) {
      assert.fail(`STILLFAIL_REQUIRE_DUAL_READER=1 requires native mesh.node addon: ${(err as Error).message}`);
    }
    meshNative = null;
  }
  if (meshNative) {
    const frontSock = join(dir, "front.sock");
    frontProc = new MbProcess(bins.pion, ["--builder", "mesh", "--socket", frontSock, "--shell-dir", join(dir, "shell")]);
    await new Promise<void>((resolve, reject) => {
      frontProc!.once("message", (m: { listening?: string }) =>
        m.listening === frontSock ? resolve() : reject(new Error(JSON.stringify(m))),
      );
      frontProc!.once("exit", (code: number) => reject(new Error(`front exited (${code})`)));
    });

    const ALPN = Buffer.from("stillfail/test/w7g-serve");
    const mesh = withFront(meshNative, frontSock);
    station = await mesh.bind({ secretKey: Buffer.alloc(32, 3), alpns: [ALPN], relayUrls: [], discovery: false });
    device = await meshNative.bind({ secretKey: Buffer.alloc(32, 5), alpns: [ALPN], relayUrls: [], discovery: false });
    assert.equal(await station.route!(ALPN, paths, SERVED_ROUTES), true);

    const addrOf = (e: Endpoint) => ({
      id: e.id(),
      ips: e.sockets()
        .filter((s) => /^\d/.test(s))
        .map((s) => s.replace(/^0\.0\.0\.0/, "127.0.0.1")),
    });
    const readAll = async (s: Stream): Promise<Buffer> => {
      const chunks: Buffer[] = [];
      for (let b = await s.read(); b !== null; b = await s.read()) chunks.push(b);
      return Buffer.concat(chunks);
    };

    const acceptedP = station.accept();
    const clientConn = await device.connect(addrOf(station), ALPN);
    const stationConn = (await acceptedP)!;
    const credStream = await clientConn.openBi();
    await credStream.write(Buffer.from('{"hello":1}\n'));
    const credAccepted = (await stationConn.acceptBi())!;
    assert.equal((await credAccepted.read())!.toString(), '{"hello":1}\n');
    served.viewer(stationConn.handed!, BASE_VIEWER);

    const s = await clientConn.openBi();
    await s.write(Buffer.from(`${JSON.stringify({ method: "GET", path: "/admin/api/sessions", headers: BASE_HEADERS })}\n`));
    await s.finish();
    const resp = await readAll(s);
    const nl = resp.indexOf(0x0a);
    const head = JSON.parse(resp.subarray(0, nl).toString("utf8"));
    const bodyBuf = resp.subarray(nl + 1);
    const decoded = head.headers["content-encoding"] === "zstd" ? zstdDecompressSync(bodyBuf) : bodyBuf;
    const sessions = JSON.parse(decoded.toString("utf8"));
    assert.equal(head.status, 200);
    assert.ok(Array.isArray(sessions) && sessions.length >= 5, "expected Pion --serve to return sessions list over mesh");
  }
});
