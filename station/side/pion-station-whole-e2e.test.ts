// Wave 16B/17A Real-Machine End-to-End Suite for `stillfail-station-pion` Whole Daemon (`whole_daemon.pion`):
// 1. `--version` advertises `roles:rig,whole` (W17A cutover) + `--smoke-js-lower` full Unicode parity.
// 2. SQLite handover barrier + >= 3 queued RPCs strict FIFO replay + direct iroh `stillfail/http/1` interop
//    (using production `station/src/mesh/wire.ts` `writeLine` / `Reader`, half-open SSE without client FIN,
//    `ownPorts` refusal, and `tcp: true` / `probe: true`).
// 3. REAL Rust Launcher + MB Front (`front.sock`):
//    - Cryptographically signed Ed25519 JWT member auth on `stillfail/admin/1` (`ALPN`) stream 1 +
//      streams 2..N (`/status`, `/sessions`, `/threads/:id/messages`, `/chats`, `/search` Unicode,
//      half-open `/events` SSE with `running=1`, `OLDEST_CORE` 426 gate, truncated body 400);
//    - Anti-privilege-escalation: roster station calling `POST /sessions` over `PEER_BYTES_ALPN` returns `403`;
//    - Production `stillfail/http/1` (`PEER_HTTP_ALPN`) over `front.sock` using `writeLine`/`Reader` to real
//      local loopback HTTP + SSE + TCP echo servers + `ownPorts` refusal;
//    - Backpressured large Drive upload/download (4 MiB) with slow reader verifying bounded RSS;
//    - 60 sequential requests over real launcher + `front.sock` verifying `/proc/<pid>/fd` zero growth;
//    - Inherited `mcpFd` + MCP lifecycle (`chat_create`, `chat_list`, `search`, `job_start`, `job_list`, archive -> 401);
//    - Real `SIGUSR2` `Pion Whole -> Pion Whole` hot handover preserving live `sleep 30` job PID + visible in
//      new daemon's `job_list`, plus sessions/messages/tokens intact and zero orphans.
// 4. `BecameRig` mode switch: live presence frame marking station rig-only triggers handover stop cleanly.
import assert from "node:assert/strict";
import { type ChildProcess, execFileSync, spawn, spawnSync } from "node:child_process";
import { createHash, generateKeyPairSync, randomBytes, sign as cryptoSign } from "node:crypto";
import { createSocket as createUdpSocket } from "node:dgram";
import { chmodSync, copyFileSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { createServer as createHttpServer, request as httpRequest, type Server as HttpServer } from "node:http";
import { createConnection, createServer as createNetServer, type Server as NetServer } from "node:net";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import type { Duplex } from "node:stream";
import { after, test } from "node:test";
import { fileURLToPath } from "node:url";
import { DatabaseSync } from "node:sqlite";
import { WebSocketServer } from "ws";
import { type Entry, apply as lockApply, endpointBytes, entryHash, genesis as lockGenesis, signedBytes } from "../../shared/lock.ts";
import { loadMesh, type Connection, type Endpoint } from "../src/mesh/native.ts";
import { PEER_BYTES_ALPN } from "../src/mesh/peer.ts";
import { PEER_HTTP_ALPN } from "../src/mesh/peer-http.ts";
import { ALPN as ADMIN_ALPN } from "../src/mesh/serve.ts";
import { Reader, writeLine } from "../src/mesh/wire.ts";

const root = fileURLToPath(new URL("../..", import.meta.url));
const dirs: string[] = [];
const children: ChildProcess[] = [];
const endpoints: Endpoint[] = [];
const servers: (HttpServer | NetServer | WebSocketServer)[] = [];
const extraPids: number[] = [];

function freshDir(tag: string): string {
  const dir = mkdtempSync(join(tmpdir(), `pion-whole-e2e-${tag}-`));
  dirs.push(dir);
  return dir;
}

function isAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

function openFdCount(pid: number): number {
  try {
    return readdirSync(`/proc/${pid}/fd`).length;
  } catch {
    return -1;
  }
}

function rssBytesOf(pid: number): number {
  try {
    const statm = readFileSync(`/proc/${pid}/statm`, "utf8").trim().split(/\s+/);
    return Number(statm[1] ?? 0) * 4096;
  } catch {
    return 0;
  }
}

after(async () => {
  for (const s of servers.splice(0)) {
    try { s.close(); } catch {}
  }
  for (const ep of endpoints.splice(0)) {
    try { await ep.close(); } catch {}
  }
  for (const p of extraPids.splice(0)) {
    try { process.kill(-p, "SIGKILL"); } catch {}
    try { process.kill(p, "SIGKILL"); } catch {}
  }
  for (const c of children.splice(0)) {
    if (c.exitCode === null && c.signalCode === null) {
      try {
        if (c.pid) process.kill(-c.pid, "SIGKILL");
      } catch {}
      try { c.kill("SIGKILL"); } catch {}
    }
  }
  for (const d of dirs.splice(0)) {
    rmSync(d, { recursive: true, force: true, maxRetries: 3, retryDelay: 50 });
  }
});

function resolvePionBinary(): string {
  const envBin = process.env.STILLFAIL_STATION_PION;
  if (envBin && existsSync(envBin)) return envBin;
  const target = process.platform === "darwin" ? "darwin-arm64"
    : process.arch === "arm64" ? "linux-arm64" : "linux-x64";
  const out = join(root, "pion/station-main/_build", `stillfail-station-pion-${target}`);
  if (!existsSync(out)) {
    execFileSync("bash", [join(root, "pion/station-main/scripts/build.sh"), target, out], {
      cwd: root,
      stdio: "inherit",
    });
  }
  return out;
}

function resolveLauncherBinary(): string {
  if (process.env.STILLFAIL_LAUNCHER && existsSync(process.env.STILLFAIL_LAUNCHER)) {
    return process.env.STILLFAIL_LAUNCHER;
  }
  const target = process.platform === "darwin" ? "darwin-arm64"
    : process.arch === "arm64" ? "linux-arm64" : "linux-x64";
  const dir = execFileSync(process.execPath, [join(root, "scripts/native.ts"), "path", "launcher", target], {
    cwd: root,
    encoding: "utf8",
  }).trim();
  const candidate = join(dir, process.platform === "win32" ? "stillfail-station.exe" : "stillfail-station");
  assert.ok(existsSync(candidate), `launcher binary not found at ${candidate}`);
  return candidate;
}

function resolveReaderBinary(): string {
  if (process.env.STILLFAIL_MB_READER && existsSync(process.env.STILLFAIL_MB_READER)) {
    return process.env.STILLFAIL_MB_READER;
  }
  const target = process.platform === "darwin" ? "darwin-arm64"
    : process.arch === "arm64" ? "linux-arm64" : "linux-x64";
  const dir = execFileSync(process.execPath, [join(root, "scripts/native.ts"), "path", "reader", target], {
    cwd: root,
    encoding: "utf8",
  }).trim();
  const candidate = join(dir, process.platform === "win32" ? "stillfail-reader.exe" : "stillfail-reader");
  assert.ok(existsSync(candidate), `reader binary not found at ${candidate}`);
  return candidate;
}

function resolveRunnerBinary(): string {
  if (process.env.STILLFAIL_RUNNER && existsSync(process.env.STILLFAIL_RUNNER)) {
    return process.env.STILLFAIL_RUNNER;
  }
  const target = process.platform === "darwin" ? "darwin-arm64"
    : process.arch === "arm64" ? "linux-arm64" : "linux-x64";
  const dir = execFileSync(process.execPath, [join(root, "scripts/native.ts"), "path", "runner", target], {
    cwd: root,
    encoding: "utf8",
  }).trim();
  const candidate = join(dir, process.platform === "win32" ? "stillfail-runner.exe" : "stillfail-runner");
  assert.ok(existsSync(candidate), `runner binary not found at ${candidate}`);
  return candidate;
}

function resolveMeshAddon() {
  if (!process.env.STILLFAIL_MESH_NATIVE) {
    const target = process.platform === "darwin" ? "darwin-arm64"
      : process.arch === "arm64" ? "linux-arm64" : "linux-x64";
    const dir = execFileSync(process.execPath, [join(root, "scripts/native.ts"), "path", "mesh", target], {
      cwd: root,
      encoding: "utf8",
    }).trim();
    const candidate = join(dir, "mesh.node");
    if (existsSync(candidate)) process.env.STILLFAIL_MESH_NATIVE = candidate;
  }
  return loadMesh();
}

async function pickFreeUdpPort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const s = createUdpSocket("udp4");
    s.once("error", reject);
    s.bind(0, "127.0.0.1", () => {
      const addr = s.address();
      const port = typeof addr === "object" ? addr.port : 0;
      s.close(() => resolve(port));
    });
  });
}

async function until<T>(
  what: string,
  fn: () => T | null | undefined | false | Promise<T | null | undefined | false>,
  ms = 15_000,
): Promise<T> {
  const end = Date.now() + ms;
  let lastErr: unknown = null;
  while (Date.now() < end) {
    try {
      const v = await fn();
      if (v) return v as T;
    } catch (e) {
      lastErr = e;
    }
    await new Promise((r) => setTimeout(r, 40));
  }
  throw new Error(`timeout waiting for ${what}${lastErr ? `: ${(lastErr as Error).message}` : ""}`);
}

function httpCall(
  port: number,
  method: string,
  path: string,
  headers: Record<string, string> = {},
  body?: string | Buffer,
): Promise<{ status: number; headers: Record<string, string | string[] | undefined>; body: string }> {
  return new Promise((resolve, reject) => {
    const req = httpRequest({ host: "127.0.0.1", port, path, method, headers }, (res) => {
      const chunks: Buffer[] = [];
      res.on("data", (c) => chunks.push(c));
      res.on("end", () =>
        resolve({
          status: res.statusCode ?? 0,
          headers: res.headers,
          body: Buffer.concat(chunks).toString("utf8"),
        }),
      );
    });
    req.on("error", reject);
    if (body !== undefined) req.write(body);
    req.end();
  });
}

function makeGrantKeysAndSigner() {
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  const pubJwk = publicKey.export({ format: "jwk" }) as { kty: string; crv: string; x: string };
  const grantKeys = {
    keys: [{ kty: pubJwk.kty, crv: pubJwk.crv, x: pubJwk.x, kid: "k1" }],
  };
  const signMemberJwt = (claims: {
    ws: string;
    device: string;
    sub: string;
    email: string;
    name: string;
    role: string;
    exp?: number;
    iat?: number;
    sid?: string;
  }) => {
    const nowSec = Math.floor(Date.now() / 1000);
    const head = Buffer.from(JSON.stringify({ alg: "EdDSA", typ: "stillfail-member+jwt", kid: "k1" })).toString("base64url");
    const body = Buffer.from(
      JSON.stringify({
        iss: "stillfail-cloud",
        ws: claims.ws,
        device: claims.device,
        sub: claims.sub,
        email: claims.email,
        name: claims.name,
        role: claims.role,
        iat: claims.iat ?? nowSec - 10,
        exp: claims.exp ?? nowSec + 3600,
        sid: claims.sid ?? "sid-1",
      }),
    ).toString("base64url");
    const sig = cryptoSign(null, Buffer.from(`${head}.${body}`), privateKey).toString("base64url");
    return `${head}.${body}.${sig}`;
  };
  return { grantKeys, signMemberJwt };
}

function seedWholeDataDir(
  data: string,
  stationSeed: Buffer,
  stationId: string,
  peerId: string,
  driveRoot: string,
  ws = "ws-whole-e2e",
  grantKeys: Record<string, unknown> = {},
  origin = "",
) {
  mkdirSync(join(data, "mesh"), { recursive: true });
  mkdirSync(driveRoot, { recursive: true });
  writeFileSync(join(data, "mesh/secret.key"), stationSeed, { mode: 0o600 });
  const cloudObj = {
    origin,
    station: stationId,
    workspace: ws,
    workspace_name: "Whole E2E WS",
    name: "pion-whole-e2e",
    relay_url: "",
    relay_urls: [],
    grant_keys: grantKeys,
    peers: [{ id: peerId, name: "peer-station" }],
    revocations: [],
  };
  writeFileSync(join(data, "mesh/cloud.json"), JSON.stringify(cloudObj), { mode: 0o600 });
  writeFileSync(
    join(data, "config.json"),
    JSON.stringify({ engine: "pion", driveRoots: [driveRoot] }) + "\n",
  );
}

interface WholeHandle {
  child: ChildProcess;
  ctrl: Duplex;
  messages: Record<string, unknown>[];
  stderr: () => string;
  meshAddr: () => string | null;
  sendCtrl: (obj: Record<string, unknown>) => void;
  waitExit: (ms?: number) => Promise<number | null>;
}

function startWholeDaemon(
  bin: string,
  data: string,
  extraEnv: Record<string, string> = {},
): WholeHandle {
  const child = spawn(
    bin,
    ["run", "--whole-daemon", "--data", data, "--port", "0", "--control-fd", "5"],
    {
      stdio: ["ignore", "pipe", "pipe", "ignore", "ignore", "pipe"],
      env: {
        ...process.env,
        STILLFAIL_MESH_BIND_ADDR: "127.0.0.1:0",
        STILLFAIL_NO_DISCOVERY: "1",
        STILLFAIL_NO_DHT: "1",
        ...extraEnv,
      },
    },
  );
  children.push(child);
  const ctrl = (child.stdio as unknown[])[5] as Duplex;
  const messages: Record<string, unknown>[] = [];
  let ctrlBuf = "";
  ctrl.on("data", (chunk: Buffer) => {
    ctrlBuf += chunk.toString("utf8");
    let nl = ctrlBuf.indexOf("\n");
    while (nl >= 0) {
      const line = ctrlBuf.slice(0, nl).trim();
      ctrlBuf = ctrlBuf.slice(nl + 1);
      if (line) {
        try { messages.push(JSON.parse(line)); } catch {}
      }
      nl = ctrlBuf.indexOf("\n");
    }
  });
  let errText = "";
  child.stderr?.on("data", (c: Buffer) => { errText += c.toString("utf8"); });
  const exitPromise = new Promise<number | null>((resolve) => {
    child.once("exit", (code) => resolve(code));
  });
  return {
    child,
    ctrl,
    messages,
    stderr: () => errText,
    meshAddr: () => {
      const m = /sockets=\["(127\.0\.0\.1:\d+)"/.exec(errText);
      return m ? m[1]! : null;
    },
    sendCtrl: (obj) => { ctrl.write(JSON.stringify(obj) + "\n"); },
    waitExit: (ms = 10_000) => Promise.race([
      exitPromise,
      new Promise<never>((_, rej) => setTimeout(() => rej(new Error(`whole_daemon did not exit in ${ms}ms; stderr:\n${errText}`)), ms)),
    ]),
  };
}

async function peerRpc(
  ep: Endpoint,
  stationId: string,
  addr: string,
  workspace: string,
  request: Record<string, unknown>,
  binaryTail?: Buffer,
  timeoutMs = 8_000,
): Promise<{ result: any; binary: Buffer | null }> {
  const run = async () => {
    const conn = await ep.connect({ id: stationId, relays: [], ips: [addr] }, PEER_BYTES_ALPN);
    try {
      const stream = await conn.openBi();
      const env: Record<string, unknown> = { workspace, request };
      if (binaryTail) env.bytes = true;
      await stream.write(Buffer.from(JSON.stringify(env) + "\n"));
      if (binaryTail && binaryTail.length > 0) {
        await stream.write(binaryTail);
      }
      await stream.finish();
      const chunks: Buffer[] = [];
      for (;;) {
        const c = await stream.read();
        if (c === null) break;
        chunks.push(c);
      }
      const all = Buffer.concat(chunks);
      const nl = all.indexOf(10);
      const headerStr = (nl >= 0 ? all.subarray(0, nl) : all).toString("utf8").trim();
      const tail = nl >= 0 && nl + 1 < all.length ? all.subarray(nl + 1) : null;
      const parsed = JSON.parse(headerStr);
      if ("error" in parsed) throw new Error(String(parsed.error));
      return { result: parsed.result, binary: parsed.bytes ? (tail ?? Buffer.alloc(0)) : null };
    } finally {
      await conn.close(0, "done");
    }
  };
  return Promise.race([
    run(),
    new Promise<never>((_, rej) =>
      setTimeout(() => rej(new Error(`peerRpc(${String(request.method)}) timed out after ${timeoutMs}ms`)), timeoutMs),
    ),
  ]);
}

async function openAdminConn(
  ep: Endpoint,
  stationId: string,
  addr: string,
  credential: string,
  lock?: Record<string, unknown>,
): Promise<{ conn: Connection; ctrl: Awaited<ReturnType<Connection["openBi"]>>; ctrlReader: Reader; helloReply: any }> {
  const conn = await ep.connect({ id: stationId, relays: [], ips: [addr] }, ADMIN_ALPN);
  const ctrl = await conn.openBi();
  const payload: Record<string, unknown> = { credential };
  if (lock) payload.lock = lock;
  await writeLine(ctrl, payload);
  const ctrlReader = new Reader(ctrl);
  const helloReply = await ctrlReader.line();
  return { conn, ctrl, ctrlReader, helloReply };
}

async function adminCall(
  conn: Connection,
  method: string,
  path: string,
  headers: Record<string, string> = {},
  body?: Buffer,
  timeoutMs = 15_000,
): Promise<{ status: number; headers: Record<string, string>; body: Buffer }> {
  const run = async () => {
    const stream = await conn.openBi();
    await writeLine(stream, { method, path, headers });
    if (body && body.length > 0) {
      await stream.write(body);
    }
    await stream.finish();
    const reader = new Reader(stream);
    const head = await reader.line();
    assert.ok(head && typeof head.status === "number", `expected admin head json, got: ${JSON.stringify(head)}`);
    const respBody = await reader.rest();
    return { status: head.status, headers: head.headers ?? {}, body: respBody };
  };
  return Promise.race([
    run(),
    new Promise<never>((_, rej) =>
      setTimeout(() => rej(new Error(`adminCall(${method} ${path}) timed out after ${timeoutMs}ms`)), timeoutMs),
    ),
  ]);
}

async function startLocalTestServices(): Promise<{ httpPort: number; tcpPort: number; pushSse: (msg: string) => void }> {
  const sseRes: import("node:http").ServerResponse[] = [];
  const httpSrv = createHttpServer((req, res) => {
    if (req.url === "/hello") {
      res.writeHead(200, { "content-type": "application/json", "x-upstream": "local-ok" });
      res.end(JSON.stringify({ ok: true, method: req.method, path: req.url }));
      return;
    }
    if (req.url === "/sse") {
      res.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-cache" });
      res.write("event: ready\ndata: initial-chunk\n\n");
      sseRes.push(res);
      req.on("close", () => {
        const idx = sseRes.indexOf(res);
        if (idx >= 0) sseRes.splice(idx, 1);
      });
      return;
    }
    res.writeHead(404);
    res.end("not found");
  });
  servers.push(httpSrv);
  await new Promise<void>((r) => httpSrv.listen(0, "127.0.0.1", () => r()));
  const httpAddr = httpSrv.address();
  const httpPort = typeof httpAddr === "object" && httpAddr ? httpAddr.port : 0;

  const tcpSrv = createNetServer((sock) => {
    sock.on("data", (d) => sock.write(Buffer.concat([Buffer.from("ECHO:"), d])));
  });
  servers.push(tcpSrv);
  await new Promise<void>((r) => tcpSrv.listen(0, "127.0.0.1", () => r()));
  const tcpAddr = tcpSrv.address();
  const tcpPort = typeof tcpAddr === "object" && tcpAddr ? tcpAddr.port : 0;

  return {
    httpPort,
    tcpPort,
    pushSse: (msg: string) => {
      for (const r of sseRes) {
        r.write(`event: tick\ndata: ${msg}\n\n`);
      }
    },
  };
}

const bin = resolvePionBinary();

test("W16B.1: --version advertises roles:rig,whole and --smoke-js-lower passes full 0x0001..=0x1E950 + Final_Sigma + NULL + >4096B parity", () => {
  const ver = spawnSync(bin, ["--version"], { encoding: "utf8", timeout: 10_000 });
  assert.equal(ver.status, 0, ver.stderr);
  assert.equal(
    ver.stdout.trim(),
    "stillfail-station-pion 0.1.0 roles:rig,whole commands:id,status,lock,channel,enroll,update,heap,admin,worktree",
  );

  const jsl = spawnSync(bin, ["--smoke-js-lower"], { encoding: "utf8", timeout: 15_000 });
  assert.equal(jsl.status, 0, jsl.stderr);
  const out = JSON.parse(jsl.stdout.trim());
  assert.equal(out.ok, true);
  assert.ok(out.codepoints >= 120_000, `expected >= 120000 codepoints checked, got ${out.codepoints}`);
  assert.equal(out.final_sigma, true);
  assert.equal(out.null, true);
  assert.ok(out.long_bytes > 4096, `expected long_bytes > 4096, got ${out.long_bytes}`);
});

test("W16B.2: SQLite handover barrier + >= 3 queued RPCs strict FIFO replay + direct iroh stillfail/http/1 (wire.ts)", { skip: process.platform === "win32" }, async () => {
  const addon = resolveMeshAddon();
  const data = freshDir("barrier-data");
  const drive = freshDir("barrier-drive");
  const stSeed = randomBytes(32);
  const probe = await addon.bind({ secretKey: stSeed, alpns: [], relayUrls: [], discovery: false, dht: false, bindAddr: "127.0.0.1:0" });
  const stationId = probe.id();
  await probe.close();

  const peerEp = await addon.bind({
    secretKey: randomBytes(32),
    alpns: [PEER_BYTES_ALPN, PEER_HTTP_ALPN, ADMIN_ALPN],
    relayUrls: [],
    discovery: false,
    dht: false,
    bindAddr: "127.0.0.1:0",
  });
  endpoints.push(peerEp);
  const ws = "ws-barrier";
  seedWholeDataDir(data, stSeed, stationId, peerEp.id(), drive, ws);

  const prev = spawn("sleep", ["30"], { stdio: "ignore" });
  children.push(prev);
  assert.ok(prev.pid && prev.pid > 1);
  mkdirSync(join(data, "run"), { recursive: true });
  writeFileSync(join(data, "run/hub.json"), JSON.stringify({ pid: prev.pid }) + "\n");

  const wd = startWholeDaemon(bin, data);
  await until("ready while predecessor alive", () => wd.messages.find((m) => m.ready === true));
  const mcpMsg = await until("serving mcp before handover completes", () => wd.messages.find((m) => m.serving === "mcp"));
  const mcpPort = Number(mcpMsg.port);
  assert.ok(mcpPort > 0);
  const meshAddr = await until("whole_daemon mesh bound", () => wd.meshAddr());

  // While predecessor is STILL ALIVE:
  const preMcp = await httpCall(mcpPort, "POST", "/mcp", { "content-type": "application/json" }, "{}");
  assert.equal(preMcp.status, 503, `expected 503 before handover, got ${preMcp.status}: ${preMcp.body}`);
  assert.equal(preMcp.body.includes(data), false, "503 must not leak internal data path");
  assert.equal(existsSync(join(data, "stillfail.db")), false, "SQLite DB must not be opened before predecessor exits");

  // Queue >= 3 sequential RPCs on ONE connection BEFORE predecessor exits -> must wait until
  // predecessor exits, then replay FIFO and all complete cleanly!
  const fifoConn = await peerEp.connect({ id: stationId, relays: [], ips: [meshAddr] }, PEER_BYTES_ALPN);
  let completedCount = 0;
  const queuedStreams: Promise<any>[] = [];
  for (let idx = 1; idx <= 3; idx++) {
    const s = await fifoConn.openBi();
    await writeLine(s, { workspace: ws, request: { method: "describe", seq: idx } });
    await s.finish();
    await new Promise((r) => setTimeout(r, 25));
    queuedStreams.push(
      (async () => {
        const rd = new Reader(s);
        const ans = await rd.line();
        completedCount++;
        return ans;
      })(),
    );
  }
  await new Promise((r) => setTimeout(r, 120));
  assert.equal(completedCount, 0, "no queued RPC may complete while predecessor is alive");
  assert.equal(existsSync(join(data, "stillfail.db")), false, "SQLite DB still unopened while 3 RPCs queued");

  // End predecessor -> atomic takeover -> all 3 queued RPCs replay FIFO!
  prev.kill("SIGKILL");
  await new Promise<void>((r) => prev.once("exit", () => r()));

  const fifoAnswers = await Promise.all(queuedStreams);
  await fifoConn.close(0, "done");
  assert.equal(fifoAnswers.length, 3);
  for (const ans of fifoAnswers) {
    assert.equal(ans.result.mode, "full");
    assert.equal(ans.result.primaryOpen, true);
  }
  assert.equal(JSON.parse(readFileSync(join(data, "run/hub.json"), "utf8")).pid, wd.child.pid);
  assert.equal(existsSync(join(data, "stillfail.db")), true, "SQLite DB opened after predecessor exited");

  const postMcp = await httpCall(mcpPort, "POST", "/mcp", { "content-type": "application/json" }, "{}");
  assert.equal(postMcp.status, 401, `expected 401 (ready, no bearer) after handover, got ${postMcp.status}`);

  // Direct iroh `stillfail/http/1` interop using production `wire.ts` `writeLine` / `Reader` (HTTP + half-open SSE + TCP + ownPorts)!
  const svc = await startLocalTestServices();
  const httpConn = await peerEp.connect({ id: stationId, relays: [], ips: [meshAddr] }, PEER_HTTP_ALPN);
  try {
    // 1. Normal HTTP proxy
    const s1 = await httpConn.openBi();
    await writeLine(s1, { workspace: ws, port: svc.httpPort, method: "GET", path: "/hello", headers: [] });
    await s1.finish();
    const r1 = new Reader(s1);
    const h1 = await r1.line();
    assert.equal(h1.status, 200);
    const b1 = JSON.parse((await r1.rest()).toString("utf8"));
    assert.equal(b1.ok, true);
    assert.equal(b1.path, "/hello");

    // 2. Half-open SSE over direct iroh `stillfail/http/1` WITHOUT calling `finish()`!
    const s2 = await httpConn.openBi();
    await writeLine(s2, { workspace: ws, port: svc.httpPort, method: "GET", path: "/sse", headers: [] });
    const r2 = new Reader(s2);
    const h2 = await r2.line();
    assert.equal(h2.status, 200);
    let sseBuf = r2.carry.toString("utf8");
    while (!sseBuf.includes("initial-chunk")) {
      const c = await s2.read();
      assert.notEqual(c, null);
      sseBuf += c!.toString("utf8");
    }
    svc.pushSse("direct-live-1");
    while (!sseBuf.includes("direct-live-1")) {
      const c = await s2.read();
      assert.notEqual(c, null);
      sseBuf += c!.toString("utf8");
    }
    await s2.finish();

    // 3. `ownPorts` refusal (mcpPort)
    const s3 = await httpConn.openBi();
    await writeLine(s3, { workspace: ws, port: mcpPort, method: "GET", path: "/healthz", headers: [] });
    await s3.finish();
    const r3 = new Reader(s3);
    const h3 = await r3.line();
    assert.equal(h3.status, 403, `ownPort mcpPort must be refused with 403, got ${JSON.stringify(h3)}`);

    // 4. `tcp: true` probe + raw tunnel
    const s4 = await httpConn.openBi();
    await writeLine(s4, { workspace: ws, port: svc.tcpPort, tcp: true, probe: true });
    await s4.finish();
    const r4 = new Reader(s4);
    assert.equal((await r4.line()).status, 200);

    const s5 = await httpConn.openBi();
    await writeLine(s5, { workspace: ws, port: svc.tcpPort, tcp: true });
    const r5 = new Reader(s5);
    assert.equal((await r5.line()).status, 200);
    await s5.write(Buffer.from("ping-tcp"));
    let echoBuf = r5.carry.toString("utf8");
    while (!echoBuf.includes("ECHO:ping-tcp")) {
      const c = await s5.read();
      assert.notEqual(c, null);
      echoBuf += c!.toString("utf8");
    }
    await s5.finish();
  } finally {
    await httpConn.close(0, "done");
  }

  wd.sendCtrl({ op: "stop" });
  assert.equal(await wd.waitExit(), 0, wd.stderr());
});

test("W16B.3-6: REAL Rust Launcher + MB Front: admin/1 JWT auth, anti-escalation 403, http/1 wire.ts, backpressured 4MiB Drive, 60-req zero-fd-leak, MCP + SIGUSR2 handover preserving live job", { skip: process.platform === "win32" }, async () => {
  const launcher = resolveLauncherBinary();
  const readerBin = resolveReaderBinary();
  const addon = resolveMeshAddon();
  const { grantKeys, signMemberJwt } = makeGrantKeysAndSigner();

  const app = freshDir("whole-launcher-app");
  const data = freshDir("whole-launcher-data");
  const drive = freshDir("whole-launcher-drive");
  mkdirSync(join(app, "station"), { recursive: true });
  copyFileSync(readerBin, join(app, "station", "stillfail-reader"));
  chmodSync(join(app, "station", "stillfail-reader"), 0o755);
  writeFileSync(join(app, "station", "main.js"), "process.exit(99);\n");
  writeFileSync(join(app, "BUILD"), "9916\n");

  const installedPion = join(app, "station", "stillfail-station-pion");
  copyFileSync(bin, installedPion);
  chmodSync(installedPion, 0o755);

  const stSeed = randomBytes(32);
  const probe = await addon.bind({ secretKey: stSeed, alpns: [], relayUrls: [], discovery: false, dht: false, bindAddr: "127.0.0.1:0" });
  const stationId = probe.id();
  await probe.close();

  const peerStation = await addon.bind({
    secretKey: randomBytes(32),
    alpns: [PEER_BYTES_ALPN, PEER_HTTP_ALPN, ADMIN_ALPN],
    relayUrls: [],
    discovery: false,
    dht: false,
    bindAddr: "127.0.0.1:0",
  });
  endpoints.push(peerStation);

  const memberEp = await addon.bind({
    secretKey: randomBytes(32),
    alpns: [ADMIN_ALPN],
    relayUrls: [],
    discovery: false,
    dht: false,
    bindAddr: "127.0.0.1:0",
  });
  endpoints.push(memberEp);

  const roguePeer = await addon.bind({
    secretKey: randomBytes(32),
    alpns: [PEER_BYTES_ALPN, PEER_HTTP_ALPN, ADMIN_ALPN],
    relayUrls: [],
    discovery: false,
    dht: false,
    bindAddr: "127.0.0.1:0",
  });
  endpoints.push(roguePeer);

  const frontPort = await pickFreeUdpPort();
  const frontAddr = `127.0.0.1:${frontPort}`;
  const ws = "ws-whole-live";
  seedWholeDataDir(data, stSeed, stationId, peerStation.id(), drive, ws, grantKeys);

  let logs = "";
  const lc = spawn(launcher, ["run", "--app", app, "--data", data], {
    stdio: ["ignore", "pipe", "pipe"],
    env: {
      ...process.env,
      STILLFAIL_NODE: process.execPath,
      STILLFAIL_MB_READER: join(app, "station", "stillfail-reader"),
      STILLFAIL_STATION_PION: installedPion,
      STILLFAIL_STATION_ENGINE: "pion",
      STILLFAIL_STATION_ENGINE_STRICT: "1",
      STILLFAIL_NO_DISCOVERY: "1",
      STILLFAIL_NO_DHT: "1",
      STILLFAIL_MESH_BIND_ADDR: frontAddr,
    },
  });
  children.push(lc);
  lc.stdout?.on("data", (d) => { logs += d.toString("utf8"); });
  lc.stderr?.on("data", (d) => { logs += d.toString("utf8"); });
  const lcExit = new Promise<number | null>((resolve) => lc.once("exit", (code) => resolve(code)));

  const readHubPid = () => {
    try {
      const j = JSON.parse(readFileSync(join(data, "run/hub.json"), "utf8"));
      return typeof j.pid === "number" && j.pid > 0 ? j.pid : null;
    } catch { return null; }
  };
  const readMcpPort = () => {
    try {
      const j = JSON.parse(readFileSync(join(data, "run/mcp.json"), "utf8"));
      return typeof j.port === "number" && j.port > 0 ? j.port : null;
    } catch { return null; }
  };
  const readAdminPort = () => {
    try {
      const j = JSON.parse(readFileSync(join(data, "run/ports.json"), "utf8"));
      return typeof j.admin === "number" && j.admin > 0 ? j.admin : null;
    } catch { return null; }
  };

  let pid1: number;
  try {
    pid1 = await until("whole_daemon hub.json pid", () => readHubPid(), 15_000);
  } catch (e) {
    throw new Error(`${(e as Error).message}\nlauncher logs:\n${logs}`);
  }
  const adminPort = await until("admin port", () => readAdminPort(), 10_000);
  const mcpPort = await until("mcp.json port", () => readMcpPort(), 10_000);
  await until("/healthz 200", async () => (await httpCall(adminPort, "GET", "/healthz")).status === 200, 10_000);
  await until("front.sock bound & describe ready", async () => {
    try {
      const r = await peerRpc(peerStation, stationId, frontAddr, ws, { method: "describe" }, undefined, 3_000);
      return r.result?.mode === "full" && r.result?.primaryOpen === true ? r : null;
    } catch { return null; }
  }, 15_000);

  // ── Part A: Fail-closed rogue peer rejection + Anti-privilege-escalation (roster station POST /sessions -> 403) ──
  await assert.rejects(
    () => peerRpc(roguePeer, stationId, frontAddr, ws, { method: "describe" }, undefined, 4_000),
    /not another station|outside|refused|closed|error/i,
    "rogue peer RPC must be fail-closed rejected",
  );
  // Roster station attempting to forge owner headers and call POST /sessions MUST get 403!
  const escRes = await peerRpc(peerStation, stationId, frontAddr, ws, {
    method: "http",
    httpMethod: "POST",
    path: "/sessions",
    headers: [
      ["x-stillfail-email", "evil@example.com"],
      ["x-stillfail-role", "owner"],
      ["content-type", "application/json"],
    ],
    body: JSON.stringify({ key: "forged-session", title: "Should Fail" }),
  });
  assert.equal(escRes.result.status, 403, `roster station POST /sessions MUST return 403, got: ${JSON.stringify(escRes.result)}`);

  // Forged JWT on `stillfail/admin/1` MUST be refused on stream 1!
  const wrongDeviceJwt = signMemberJwt({
    ws,
    device: peerStation.id(), // wrong device id for roguePeer
    sub: "u-alice",
    email: "alice@example.com",
    name: "Alice",
    role: "owner",
  });
  const badAdmin = await openAdminConn(roguePeer, stationId, frontAddr, wrongDeviceJwt);
  assert.ok(badAdmin.helloReply?.error, `expected refusal on wrong-device JWT, got: ${JSON.stringify(badAdmin.helloReply)}`);
  await badAdmin.conn.close(0, "done");

  // ── Part B: `stillfail/admin/1` Cryptographic Member Auth + AdminApi + Unicode Search + OLDEST_CORE + Truncated Body ──
  const memberJwt = signMemberJwt({
    ws,
    device: memberEp.id(),
    sub: "u-alice",
    email: "alice@example.com",
    name: "Alice",
    role: "owner",
  });
  const { conn: adminConn, helloReply } = await openAdminConn(memberEp, stationId, frontAddr, memberJwt);
  assert.equal(helloReply?.ok, true, `admin hello failed: ${JSON.stringify(helloReply)}`);
  assert.equal(helloReply?.role, "owner");

  try {
    // OLDEST_CORE floor check on `/status` (`COUNTED_FROM=1000 <= 1001 < OLDEST_CORE=7917`)
    const oldCoreResp = await adminCall(adminConn, "GET", "/status", { "stillfail-build": "1001" });
    assert.equal(oldCoreResp.status, 426, `expected 426 for old core build, got ${oldCoreResp.status}`);

    // Truncated fixed Content-Length body MUST return 400 (never dispatched!)
    const truncResp = await adminCall(
      adminConn,
      "POST",
      "/sessions",
      { "content-type": "application/json", "content-length": "500" },
      Buffer.from('{"key":"trunc"}'),
    );
    assert.equal(truncResp.status, 400, `truncated body must return 400, got ${truncResp.status}`);

    const statusResp = await adminCall(adminConn, "GET", "/status");
    assert.equal(statusResp.status, 200, statusResp.body.toString("utf8"));
    const statusJson = JSON.parse(statusResp.body.toString("utf8"));
    assert.equal(statusJson.station, stationId);
    assert.equal(statusJson.workspace, ws);

    const sessCreate = await adminCall(
      adminConn,
      "POST",
      "/sessions",
      { "content-type": "application/json" },
      Buffer.from(JSON.stringify({ key: "sess-unicode-1", title: "Greek & Turkish" })),
    );
    assert.equal(sessCreate.status, 200, sessCreate.body.toString("utf8"));
    const createdSess = JSON.parse(sessCreate.body.toString("utf8"));
    const threadId = Number(createdSess.thread);
    assert.ok(threadId > 0);

    const post1 = await adminCall(
      adminConn,
      "POST",
      `/threads/${threadId}/messages`,
      { "content-type": "application/json" },
      Buffer.from(JSON.stringify({ text: "Άννα İZMİR 300K" })),
    );
    assert.equal(post1.status, 200);

    const post2 = await adminCall(
      adminConn,
      "POST",
      `/threads/${threadId}/messages`,
      { "content-type": "application/json" },
      Buffer.from(JSON.stringify({ text: "only mİx here" })),
    );
    assert.equal(post2.status, 200);

    const chatsResp = await adminCall(adminConn, "GET", "/chats");
    assert.equal(chatsResp.status, 200);
    assert.ok(JSON.parse(chatsResp.body.toString("utf8")).total >= 1);

    const searchHit = await adminCall(adminConn, "GET", `/search?q=${encodeURIComponent("άννα 300k")}`);
    assert.equal(searchHit.status, 200);
    const msgGroup = (JSON.parse(searchHit.body.toString("utf8")).groups ?? []).find((g: any) => g.kind === "message");
    assert.ok(msgGroup && msgGroup.hits.length >= 1, "expected Unicode search hit");

    const searchNoMix = await adminCall(adminConn, "GET", "/search?q=mix");
    assert.equal(searchNoMix.status, 200);
    const noMixMsg = (JSON.parse(searchNoMix.body.toString("utf8")).groups ?? []).find((g: any) => g.kind === "message");
    assert.equal(noMixMsg?.hits?.length ?? 0, 0, "mix MUST NOT falsely match mİx");

    // ── Part C: Half-open `/events?running=1` SSE over `stillfail/admin/1` (NO client FIN, single subscription!) ──
    const sseStream = await adminConn.openBi();
    await writeLine(sseStream, { method: "GET", path: "/events?running=1", headers: {} });
    const sseReader = new Reader(sseStream);
    const sseHead = await sseReader.line();
    assert.equal(sseHead.status, 200);
    assert.equal(sseHead.headers["stillfail-follows"], "running", `expected stillfail-follows=running, got ${JSON.stringify(sseHead.headers)}`);
    let sseText = sseReader.carry.toString("utf8");
    const readSseUntil = async (needle: string, timeoutMs = 6_000) => {
      const deadline = Date.now() + timeoutMs;
      while (!sseText.includes(needle) && Date.now() < deadline) {
        const c = await Promise.race([
          sseStream.read(),
          new Promise<never>((_, rej) => setTimeout(() => rej(new Error(`timeout waiting for SSE '${needle}'; got:\n${sseText}`)), Math.max(100, deadline - Date.now()))),
        ]);
        assert.notEqual(c, null, `SSE stream ended before '${needle}'`);
        sseText += c!.toString("utf8");
      }
      assert.ok(sseText.includes(needle));
    };
    await readSseUntil("event: made");
    const postLive = await adminCall(
      adminConn,
      "POST",
      `/threads/${threadId}/messages`,
      { "content-type": "application/json" },
      Buffer.from(JSON.stringify({ text: "live-sse-ping" })),
    );
    assert.equal(postLive.status, 200);
    await readSseUntil("live-sse-ping");
    await sseStream.finish();

    // ── Part D: Backpressured 4 MiB Drive Upload + Slow-Reader Download + OLDEST_CORE on Drive ──
    mkdirSync(join(drive, "nested"), { recursive: true });
    const oldDriveRead = await adminCall(
      adminConn,
      "GET",
      `/drive/read?root=${encodeURIComponent(drive)}&path=nested/blob.bin&offset=0&length=1048576`,
      { "stillfail-build": "1001" },
    );
    assert.equal(oldDriveRead.status, 426, "OLDEST_CORE must gate Drive download fast path");

    const bigPayload = randomBytes(4 * 1024 * 1024);
    const upResp = await adminCall(
      adminConn,
      "PUT",
      `/drive/upload?root=${encodeURIComponent(drive)}&path=nested/big.bin&id=up-big&offset=0&total=${bigPayload.length}&replace=1`,
      { "content-type": "application/octet-stream", "content-length": String(bigPayload.length) },
      bigPayload,
      30_000,
    );
    assert.equal(upResp.status, 200, upResp.body.toString("utf8"));
    assert.equal(JSON.parse(upResp.body.toString("utf8")).have, bigPayload.length);

    // Slow-reader download of 4 MiB file: pause briefly every 256 KiB and check daemon RSS stays bounded!
    const rssBefore = rssBytesOf(pid1);
    const dlStream = await adminConn.openBi();
    await writeLine(dlStream, {
      method: "GET",
      path: `/drive/read?root=${encodeURIComponent(drive)}&path=nested/big.bin&offset=0&length=${bigPayload.length}`,
      headers: {},
    });
    await dlStream.finish();
    const dlReader = new Reader(dlStream);
    const dlHead = await dlReader.line();
    assert.equal(dlHead.status, 200);
    assert.equal(dlHead.headers["stillfail-total"], String(bigPayload.length));
    const dlParts: Buffer[] = dlReader.carry.length > 0 ? [dlReader.carry] : [];
    let gotBytes = dlReader.carry.length;
    let nextPause = 256 * 1024;
    for (;;) {
      const c = await dlStream.read();
      if (c === null) break;
      dlParts.push(c);
      gotBytes += c.length;
      if (gotBytes >= nextPause) {
        nextPause += 256 * 1024;
        await new Promise((r) => setTimeout(r, 15));
      }
    }
    const dlBuf = Buffer.concat(dlParts);
    assert.equal(Buffer.compare(dlBuf, bigPayload), 0, "4 MiB backpressured Drive download must match 1:1");
    const rssAfter = rssBytesOf(pid1);
    if (rssBefore > 0 && rssAfter > 0) {
      const rssGrowthMb = (rssAfter - rssBefore) / (1024 * 1024);
      assert.ok(rssGrowthMb < 32, `expected bounded RSS during slow 4MiB download, grew by ${rssGrowthMb.toFixed(1)} MiB`);
    }

    // ── Part E: `stillfail/http/1` over `front.sock` using production `wire.ts` `writeLine`/`Reader` ──
    const svc = await startLocalTestServices();
    const frontHttpConn = await peerStation.connect({ id: stationId, relays: [], ips: [frontAddr] }, PEER_HTTP_ALPN);
    try {
      const hs1 = await frontHttpConn.openBi();
      await writeLine(hs1, { workspace: ws, port: svc.httpPort, method: "GET", path: "/hello", headers: [] });
      await hs1.finish();
      const hr1 = new Reader(hs1);
      const hh1 = await hr1.line();
      assert.equal(hh1.status, 200);
      assert.equal(JSON.parse((await hr1.rest()).toString("utf8")).ok, true);

      // Half-open SSE over `front.sock` `stillfail/http/1` WITHOUT client FIN
      const hs2 = await frontHttpConn.openBi();
      await writeLine(hs2, { workspace: ws, port: svc.httpPort, method: "GET", path: "/sse", headers: [] });
      const hr2 = new Reader(hs2);
      const hh2 = await hr2.line();
      assert.equal(hh2.status, 200);
      let fsse = hr2.carry.toString("utf8");
      while (!fsse.includes("initial-chunk")) {
        const c = await hs2.read();
        assert.notEqual(c, null);
        fsse += c!.toString("utf8");
      }
      svc.pushSse("front-live-1");
      while (!fsse.includes("front-live-1")) {
        const c = await hs2.read();
        assert.notEqual(c, null);
        fsse += c!.toString("utf8");
      }
      await hs2.finish();

      // `ownPorts` refusal over `front.sock`
      const hs3 = await frontHttpConn.openBi();
      await writeLine(hs3, { workspace: ws, port: adminPort, method: "GET", path: "/healthz", headers: [] });
      await hs3.finish();
      const hr3 = new Reader(hs3);
      assert.equal((await hr3.line()).status, 403);

      // `socket: true` WebSocket forwarding over `front.sock` (`preview.ts` 5-byte `[kind: u8][len: u32be][payload]` framing)
      // with `Origin: http://localhost:<port>` + `Authorization` passthrough, `sec-websocket-protocol: r3.echo`,
      // 8 x 4 MiB downlink backpressure, AND 24 x 1 MiB slow-upstream uplink backpressure!
      const wsUpstreamHttp = createHttpServer((_req, res) => { res.writeHead(404); res.end(); });
      const wsUpstream = new WebSocketServer({
        noServer: true,
        maxPayload: 32 * 1024 * 1024,
        handleProtocols: (protos) => (protos.has("r3.echo") ? "r3.echo" : false),
      });
      servers.push(wsUpstreamHttp, wsUpstream);
      await new Promise<void>((r) => wsUpstreamHttp.listen(0, "127.0.0.1", () => r()));
      const wsUpPort = (wsUpstreamHttp.address() as { port: number }).port;

      wsUpstreamHttp.on("upgrade", (req, socket, head) => {
        if (req.url === "/ws") {
          // R5 Item 4: enforce `Origin: http://localhost:<port>` AND `Authorization: Bearer r5-secret`!
          if (req.headers.origin !== `http://localhost:${wsUpPort}` || req.headers.authorization !== "Bearer r5-secret") {
            socket.write("HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
            socket.destroy();
            return;
          }
        }
        wsUpstream.handleUpgrade(req, socket, head, (wsConn) => {
          wsUpstream.emit("connection", wsConn, req);
        });
      });

      let uplinkGotMsgs = 0;
      let uplinkGotBytes = 0;
      const uplinkSha = createHash("sha256");
      let uplinkDoneResolve: (() => void) | null = null;
      const uplinkDone = new Promise<void>((r) => { uplinkDoneResolve = r; });

      wsUpstream.on("connection", (sock, req) => {
        if (req.url === "/bulk32") {
          // R5 Item 2a: 8 x 4 MiB binary WS messages (33,554,432 bytes)
          const fourMb = Buffer.alloc(4 * 1024 * 1024, 0x5a);
          let idx = 0;
          const sendNext = () => {
            if (idx >= 8) {
              sock.close(1000, "bulk32-done");
              return;
            }
            const frame = Buffer.from(fourMb);
            frame[0] = idx & 0xff;
            idx++;
            sock.send(frame, { binary: true }, (err) => {
              if (!err) setImmediate(sendNext);
            });
          };
          sendNext();
          return;
        }
        if (req.url === "/slow-uplink") {
          // R5 Item 2b: Pause reading underlying TCP socket for 2s to force true uplink backpressure!
          const rawSock = (sock as any)._socket as import("node:net").Socket | undefined;
          if (rawSock) {
            rawSock.pause();
            setTimeout(() => rawSock.resume(), 2000);
          }
          sock.on("message", (data) => {
            const b = Buffer.from(data as Buffer);
            uplinkSha.update(b);
            uplinkGotMsgs++;
            uplinkGotBytes += b.length;
            if (uplinkGotMsgs === 24 && uplinkDoneResolve) {
              uplinkDoneResolve();
              uplinkDoneResolve = null;
            }
          });
          return;
        }
        sock.on("message", (data, isBinary) => {
          if (isBinary) {
            sock.send(Buffer.concat([Buffer.from([0xaa]), Buffer.from(data as Buffer)]), { binary: true });
          } else {
            sock.send(`WS-ECHO:${data.toString("utf8")}`);
          }
        });
      });

      const wsStream = await frontHttpConn.openBi();
      await writeLine(wsStream, {
        workspace: ws,
        port: wsUpPort,
        path: "/ws",
        headers: [
          ["sec-websocket-protocol", "r3.echo"],
          ["authorization", "Bearer r5-secret"],
        ],
        socket: true,
      });
      const wsReader = new Reader(wsStream);
      const wsHead = await wsReader.line();
      assert.equal(wsHead.status, 101, `expected 101 for socket:true WS proxy with localhost origin + auth, got ${JSON.stringify(wsHead)}`);
      const wsProtoHdr = (wsHead.headers as [string, string][]).find(([k]) => k.toLowerCase() === "sec-websocket-protocol");
      assert.equal(wsProtoHdr?.[1], "r3.echo", `expected sec-websocket-protocol=r3.echo, got ${JSON.stringify(wsHead.headers)}`);
      const encodeWsFrame = (kind: number, payload: Buffer) => {
        const hdr = Buffer.allocUnsafe(5);
        hdr[0] = kind;
        hdr.writeUInt32BE(payload.length, 1);
        return Buffer.concat([hdr, payload]);
      };
      await wsStream.write(encodeWsFrame(1, Buffer.from("hello-ws-r5", "utf8")));
      await wsStream.write(encodeWsFrame(2, Buffer.from([1, 2, 3, 4])));
      let wsRaw = wsReader.carry;
      const readWsFrameFrom = async (s: typeof wsStream, state: { buf: Buffer }): Promise<{ kind: number; payload: Buffer } | null> => {
        while (state.buf.length < 5) {
          const c = await s.read();
          if (c === null) return null;
          state.buf = Buffer.concat([state.buf, c]);
        }
        const kind = state.buf[0]!;
        const len = state.buf.readUInt32BE(1);
        while (state.buf.length < 5 + len) {
          const c = await s.read();
          if (c === null) return null;
          state.buf = Buffer.concat([state.buf, c]);
        }
        const payload = state.buf.subarray(5, 5 + len);
        state.buf = state.buf.subarray(5 + len);
        return { kind, payload };
      };
      const wsState = { buf: wsRaw };
      const f1 = await readWsFrameFrom(wsStream, wsState);
      assert.ok(f1);
      assert.equal(f1!.kind, 1);
      assert.equal(f1!.payload.toString("utf8"), "WS-ECHO:hello-ws-r5");
      const f2 = await readWsFrameFrom(wsStream, wsState);
      assert.ok(f2);
      assert.equal(f2!.kind, 2);
      assert.deepEqual(f2!.payload, Buffer.from([0xaa, 1, 2, 3, 4]));
      const closePayload = Buffer.allocUnsafe(2);
      closePayload.writeUInt16BE(1000, 0);
      await wsStream.write(encodeWsFrame(8, closePayload));
      await wsStream.finish();

      // R5 Item 2a: 8 x 4 MiB (> 2 MiB hard cap!) WS binary frames + 2s client read pause -> 100% SHA-256 intact, 0 reset!
      const expWsSha = createHash("sha256");
      const base4Mb = Buffer.alloc(4 * 1024 * 1024, 0x5a);
      for (let i = 0; i < 8; i++) {
        const f = Buffer.from(base4Mb);
        f[0] = i & 0xff;
        expWsSha.update(f);
      }
      const expWsDigest = expWsSha.digest("hex");
      const wsBulkStream = await frontHttpConn.openBi();
      await writeLine(wsBulkStream, { workspace: ws, port: wsUpPort, path: "/bulk32", headers: [], socket: true });
      const wsBulkReader = new Reader(wsBulkStream);
      const wsBulkHead = await wsBulkReader.line();
      assert.equal(wsBulkHead.status, 101);
      // Pause reading for 2 seconds to force 64 KiB chunked downlink WS backpressure!
      await new Promise((r) => setTimeout(r, 2000));
      const bulkState = { buf: wsBulkReader.carry };
      const actWsSha = createHash("sha256");
      let wsMsgs = 0;
      let wsBytes = 0;
      for (;;) {
        const fr = await readWsFrameFrom(wsBulkStream, bulkState);
        if (!fr) break;
        if (fr.kind === 2) {
          actWsSha.update(fr.payload);
          wsMsgs++;
          wsBytes += fr.payload.length;
        } else if (fr.kind === 8) {
          break;
        }
      }
      assert.equal(wsMsgs, 8, `expected all 8 x 4MiB WS messages without reset, got ${wsMsgs}`);
      assert.equal(wsBytes, 8 * 4 * 1024 * 1024);
      assert.equal(actWsSha.digest("hex"), expWsDigest, "8x4 MiB backpressured WS SHA-256 mismatch");
      await wsBulkStream.finish();

      // R5 Item 2b: True uplink backpressure — local WS pauses reading 2s while client pushes 24 x 1 MiB frames -> 100% received, 0 reset!
      const expUpSha = createHash("sha256");
      const base1Mb = Buffer.alloc(1024 * 1024, 0x3c);
      const wsUpStream = await frontHttpConn.openBi();
      await writeLine(wsUpStream, { workspace: ws, port: wsUpPort, path: "/slow-uplink", headers: [], socket: true });
      const wsUpReader = new Reader(wsUpStream);
      const wsUpHead = await wsUpReader.line();
      assert.equal(wsUpHead.status, 101);
      for (let i = 0; i < 24; i++) {
        const f = Buffer.from(base1Mb);
        f[0] = i & 0xff;
        expUpSha.update(f);
        await wsUpStream.write(encodeWsFrame(2, f));
      }
      await Promise.race([
        uplinkDone,
        new Promise<never>((_, rej) => setTimeout(() => rej(new Error(`uplink backpressure timeout: got ${uplinkGotMsgs}/24 (${uplinkGotBytes}B)`)), 20_000)),
      ]);
      assert.equal(uplinkGotMsgs, 24);
      assert.equal(uplinkGotBytes, 24 * 1024 * 1024);
      assert.equal(uplinkSha.digest("hex"), expUpSha.digest("hex"), "24x1 MiB uplink backpressured WS SHA-256 mismatch");
      await wsUpStream.finish();

      // 16 MiB `tcp: true` backpressure test over `front.sock`: client pauses reading for 2.5s ->
      // MUST receive 100% of 16 MiB bytes with matching SHA-256 and zero stream reset!
      const bigTcpSize = 16 * 1024 * 1024;
      const bigTcpChunk = randomBytes(64 * 1024);
      const expectedSha = createHash("sha256");
      for (let off = 0; off < bigTcpSize; off += bigTcpChunk.length) {
        expectedSha.update(bigTcpChunk);
      }
      const expectedDigest = expectedSha.digest("hex");
      const bulkTcpSrv = createNetServer((sock) => {
        let sent = 0;
        const pump = () => {
          while (sent < bigTcpSize) {
            const ok = sock.write(bigTcpChunk);
            sent += bigTcpChunk.length;
            if (!ok) {
              sock.once("drain", pump);
              return;
            }
          }
          sock.end();
        };
        pump();
      });
      servers.push(bulkTcpSrv);
      await new Promise<void>((r) => bulkTcpSrv.listen(0, "127.0.0.1", () => r()));
      const bulkTcpPort = (bulkTcpSrv.address() as { port: number }).port;

      const bpStream = await frontHttpConn.openBi();
      await writeLine(bpStream, { workspace: ws, port: bulkTcpPort, tcp: true });
      const bpReader = new Reader(bpStream);
      const bpHead = await bpReader.line();
      assert.equal(bpHead.status, 200);
      const actualSha = createHash("sha256");
      let totalGot = 0;
      if (bpReader.carry.length > 0) {
        actualSha.update(bpReader.carry);
        totalGot += bpReader.carry.length;
      }
      // Pause reading for 2.5s to force backpressure on upstream TCP socket!
      await new Promise((r) => setTimeout(r, 2500));
      for (;;) {
        const c = await bpStream.read();
        if (c === null) break;
        actualSha.update(c);
        totalGot += c.length;
      }
      assert.equal(totalGot, bigTcpSize, `expected all 16 MiB (${bigTcpSize}B) without truncation/reset, got ${totalGot}B`);
      assert.equal(actualSha.digest("hex"), expectedDigest, "16 MiB backpressured tcp tunnel SHA-256 mismatch");
    } finally {
      await frontHttpConn.close(0, "done");
    }

    // ── Part F: 60 Sequential Requests over `front.sock` -> `/proc/<pid>/fd` ZERO Growth! ──
    // Warm up 2 requests first, then measure fd baseline.
    await adminCall(adminConn, "GET", "/status");
    await new Promise((r) => setTimeout(r, 100));
    const fdsBefore = openFdCount(pid1);
    for (let i = 0; i < 60; i++) {
      const r = await adminCall(adminConn, "GET", "/status");
      assert.equal(r.status, 200);
    }
    await new Promise((r) => setTimeout(r, 150));
    const fdsAfter = openFdCount(pid1);
    if (fdsBefore > 0 && fdsAfter > 0) {
      assert.ok(
        fdsAfter - fdsBefore <= 2,
        `front.sock fd leak detected! fdsBefore=${fdsBefore} fdsAfter=${fdsAfter} (+${fdsAfter - fdsBefore} over 60 requests)`,
      );
    }
  } finally {
    await adminConn.close(0, "done");
  }

  // ── Part G: Inherited `mcpFd` + MCP Lifecycle + Start Live `sleep 30` Job Before Handover ──
  const dbCheck = new DatabaseSync(join(data, "stillfail.db"), { readOnly: true });
  const tokRow = dbCheck.prepare("SELECT token FROM sessions WHERE key = ?").get("sess-unicode-1") as { token: string } | undefined;
  dbCheck.close();
  assert.ok(tokRow && /^[0-9a-f]{64}$/.test(tokRow.token), `expected 64-hex (32B) CSPRNG token, got: ${tokRow?.token}`);
  const bearerToken = tokRow!.token;

  const mcpCall = async (token: string, toolName: string, args: Record<string, unknown>) => {
    const rpc = { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: toolName, arguments: args } };
    return httpCall(
      mcpPort,
      "POST",
      "/mcp",
      {
        "content-type": "application/json",
        authorization: `Bearer ${token}`,
        host: `127.0.0.1:${mcpPort}`,
      },
      JSON.stringify(rpc),
    );
  };

  const mcpCreate = await mcpCall(bearerToken, "chat_create", {
    key: "sess-from-mcp",
    title: "Created via MCP",
    text: "mcp-sentinel-phrase",
  });
  assert.equal(mcpCreate.status, 200, mcpCreate.body);

  const mcpList = await mcpCall(bearerToken, "chat_list", {});
  assert.equal(mcpList.status, 200, mcpList.body);
  assert.ok(mcpList.body.includes("Created via MCP"), `chat_list missing MCP chat: ${mcpList.body}`);

  const mcpSearch = await mcpCall(bearerToken, "search", { query: "mcp-sentinel-phrase" });
  assert.equal(mcpSearch.status, 200, mcpSearch.body);
  assert.ok(mcpSearch.body.includes("mcp-sentinel-phrase"), `MCP search missing hit: ${mcpSearch.body}`);

  // Start a long-running job (`sleep 30`) via MCP BEFORE `SIGUSR2` handover!
  const jobStartResp = await mcpCall(bearerToken, "job_start", {
    command: "sleep 30",
    name: "handover-survivor",
  });
  assert.equal(jobStartResp.status, 200, jobStartResp.body);
  const jobListBefore = await mcpCall(bearerToken, "job_list", {});
  assert.equal(jobListBefore.status, 200, jobListBefore.body);
  assert.ok(jobListBefore.body.includes("handover-survivor"), `job_list missing started job: ${jobListBefore.body}`);

  const dbJobs = new DatabaseSync(join(data, "stillfail.db"), { readOnly: true });
  const jobRow = dbJobs.prepare("SELECT id, pgid FROM jobs WHERE name = ? ORDER BY started_at DESC LIMIT 1").get("handover-survivor") as { id: string; pgid: number } | undefined;
  dbJobs.close();
  assert.ok(jobRow && jobRow.pgid > 1, `expected persisted running job PGID in SQLite, got: ${JSON.stringify(jobRow)}`);
  const liveJobId = jobRow!.id;
  const liveJobPid = jobRow!.pgid;
  extraPids.push(liveJobPid);
  assert.equal(isAlive(liveJobPid), true, `job pid ${liveJobPid} should be alive before SIGUSR2`);

  // R5 Item 1: Seed ONE claimed runner (`claude-sess-unicode-1`, owned by `sess-unicode-1`) AND
  // ONE bystander runner (`claude-bystander-unclaimed`, owned by NO session) before `SIGUSR2` handover.
  // Assert: (1) ONLY claimed runner is attached, bystander is NOT; (2) output is persisted & exposed
  // via `GET /sessions/sess-unicode-1`; (3) `ack` carries `keep` and is sent AFTER persistence!
  const liveRunnerProc = spawn("sleep", ["30"], { stdio: "ignore" });
  const bystanderProc = spawn("sleep", ["30"], { stdio: "ignore" });
  children.push(liveRunnerProc, bystanderProc);
  assert.ok(liveRunnerProc.pid && liveRunnerProc.pid > 1);
  assert.ok(bystanderProc.pid && bystanderProc.pid > 1);
  mkdirSync(join(data, "run", "runners"), { recursive: true });
  const runnerSockPath = join(data, "run", "runners", "claude-sess-unicode-1.sock");
  const bystanderSockPath = join(data, "run", "runners", "claude-bystander-unclaimed.sock");
  let runnerAttached = false;
  let runnerAckOut = 0;
  let runnerAckKeep: number | null = null;
  let bystanderAttached = false;
  const runnerSrv = createNetServer((sock) => {
    let buf = "";
    sock.on("data", (d) => {
      buf += d.toString("utf8");
      let nl = buf.indexOf("\n");
      while (nl >= 0) {
        const line = buf.slice(0, nl).trim();
        buf = buf.slice(nl + 1);
        if (line) {
          const msg = JSON.parse(line);
          if (msg.op === "attach") {
            runnerAttached = true;
            const postLine = Buffer.from("post-handover-runner-output\n", "utf8");
            sock.write(JSON.stringify({ op: "out", stream: "out", at: 0, data: postLine.toString("base64") }) + "\n");
          } else if (msg.op === "ack" && typeof msg.out === "number") {
            runnerAckOut = msg.out;
            runnerAckKeep = typeof msg.keep === "number" ? msg.keep : null;
          }
        }
        nl = buf.indexOf("\n");
      }
    });
  });
  const bystanderSrv = createNetServer((sock) => {
    bystanderAttached = true;
    sock.destroy();
  });
  servers.push(runnerSrv, bystanderSrv);
  await new Promise<void>((r) => runnerSrv.listen(runnerSockPath, () => r()));
  await new Promise<void>((r) => bystanderSrv.listen(bystanderSockPath, () => r()));
  writeFileSync(
    join(data, "run", "runners", "claude-sess-unicode-1.json"),
    JSON.stringify({
      id: "claude-sess-unicode-1",
      runner: liveRunnerProc.pid,
      pid: liveRunnerProc.pid,
      pgid: liveRunnerProc.pid,
      startedAt: Date.now(),
      socket: runnerSockPath,
    }) + "\n",
  );
  writeFileSync(
    join(data, "run", "runners", "claude-bystander-unclaimed.json"),
    JSON.stringify({
      id: "claude-bystander-unclaimed",
      runner: bystanderProc.pid,
      pid: bystanderProc.pid,
      pgid: bystanderProc.pid,
      startedAt: Date.now(),
      socket: bystanderSockPath,
    }) + "\n",
  );

  // ── Part H: Real Rust Launcher `SIGUSR2` Hot Handover (`Pion Whole -> Pion Whole`) ──
  // Live `sleep 30` job MUST SURVIVE handover and remain visible in the new daemon's `job_list`!
  process.kill(lc.pid!, "SIGUSR2");
  const pid2 = await until("new whole_daemon pid after SIGUSR2", () => {
    const p = readHubPid();
    return p && p !== pid1 ? p : null;
  }, 20_000);
  await until("old whole_daemon pid1 exited cleanly", () => !isAlive(pid1), 15_000);
  assert.notEqual(pid2, pid1);

  // CRITICAL: job & native runner started before `SIGUSR2` MUST STILL BE ALIVE,
  // claimed runner MUST receive `attach` + `ack` with `keep`, bystander MUST NOT be attached!
  assert.equal(isAlive(liveJobPid), true, `running job pid ${liveJobPid} was killed during SIGUSR2 handover!`);
  assert.equal(isAlive(liveRunnerProc.pid), true, `native runner pid ${liveRunnerProc.pid} was killed during SIGUSR2 handover!`);
  await until("successor reconnected to adopted runner socket and acked with keep", () => runnerAttached && runnerAckOut >= 28 && runnerAckKeep === 0, 10_000);
  assert.equal(bystanderAttached, false, "unclaimed bystander runner MUST NOT be attached");
  liveRunnerProc.kill("SIGKILL");
  bystanderProc.kill("SIGKILL");

  await until("new whole_daemon MCP ready after handover", async () => {
    const r = await mcpCall(bearerToken, "job_list", {});
    return r.status === 200 && r.body.includes("handover-survivor") ? r : null;
  }, 15_000);

  // Cleanly stop the surviving job via MCP `job_stop`
  const jobStopResp = await mcpCall(bearerToken, "job_stop", { id: liveJobId });
  assert.equal(jobStopResp.status, 200, jobStopResp.body);

  // Verify old token & messages survived handover, then archive -> immediate 401!
  const postHandoverSearch = await mcpCall(bearerToken, "search", { query: "άννα 300k" });
  assert.equal(postHandoverSearch.status, 200, postHandoverSearch.body);
  assert.ok(postHandoverSearch.body.includes("Άννα") || postHandoverSearch.body.includes("sess-unicode-1"));

  const { conn: adminConn2, helloReply: hello2 } = await openAdminConn(memberEp, stationId, frontAddr, memberJwt);
  assert.equal(hello2?.ok, true);
  // R5 Item 1: Verify post-handover adopted runner output is persisted & exposed via `GET /sessions/sess-unicode-1`!
  const sessAfter = await adminCall(adminConn2, "GET", "/sessions/sess-unicode-1");
  assert.equal(sessAfter.status, 200, sessAfter.body.toString("utf8"));
  const sessAfterJson = JSON.parse(sessAfter.body.toString("utf8"));
  assert.ok(
    Array.isArray(sessAfterJson.adoptedOutput) && sessAfterJson.adoptedOutput.some((s: string) => s.includes("post-handover-runner-output")),
    `expected adoptedOutput to contain post-handover-runner-output, got: ${JSON.stringify(sessAfterJson)}`,
  );
  const archResp = await adminCall(adminConn2, "POST", "/sessions/sess-unicode-1/archive");
  assert.equal(archResp.status, 200, archResp.body.toString("utf8"));
  await adminConn2.close(0, "done");

  const revokedMcp = await mcpCall(bearerToken, "chat_list", {});
  assert.equal(revokedMcp.status, 401, `archived session token must immediately return 401, got ${revokedMcp.status}`);

  // Clean launcher shutdown -> zero orphans
  lc.kill("SIGTERM");
  assert.equal(await Promise.race([lcExit, new Promise<null>((r) => setTimeout(() => r(null), 15_000))]), 0, logs);
  await until("whole_daemon pid2 exited cleanly", () => !isAlive(pid2), 10_000);
});

test("W16B.7: BecameRig mode switch triggers handover stop when live presence transitions station to rig-only", { skip: process.platform === "win32" }, async () => {
  const addon = resolveMeshAddon();
  const data = freshDir("became-rig-data");
  const drive = freshDir("became-rig-drive");
  const stSeed = randomBytes(32);
  const probe = await addon.bind({ secretKey: stSeed, alpns: [], relayUrls: [], discovery: false, dht: false, bindAddr: "127.0.0.1:0" });
  const stationId = probe.id();
  await probe.close();

  // Local mock cloud presence WS server: on connect, sends a `state` frame promoting the already-rig
  // joined workspace `ws-rig-only` to home (removing the full workspace) -> `whole_daemon` detects
  // `is_rig_only` (`BecameRig`) and triggers clean handover stop!
  const wsHttp = createHttpServer((_req, res) => {
    res.writeHead(404);
    res.end();
  });
  const wss = new WebSocketServer({ server: wsHttp });
  servers.push(wsHttp, wss);
  wss.on("connection", (wsSock) => {
    wsSock.send(
      JSON.stringify({
        type: "state",
        workspace: "ws-rig-only",
        workspace_name: "Rig Only WS",
        name: "pion-became-rig",
        peers: [],
        workspaces: [],
        revocations: [],
      }),
    );
  });
  await new Promise<void>((r) => wsHttp.listen(0, "127.0.0.1", () => r()));
  const wsAddr = wsHttp.address();
  const wsPort = typeof wsAddr === "object" && wsAddr ? wsAddr.port : 0;

  mkdirSync(join(data, "mesh"), { recursive: true });
  mkdirSync(drive, { recursive: true });
  writeFileSync(join(data, "mesh/secret.key"), stSeed, { mode: 0o600 });
  writeFileSync(
    join(data, "mesh/cloud.json"),
    JSON.stringify({
      origin: `http://127.0.0.1:${wsPort}`,
      station: stationId,
      workspace: "ws-home-full",
      workspace_name: "Home Full WS",
      name: "pion-became-rig",
      relay_url: "",
      relay_urls: [],
      grant_keys: {},
      peers: [],
      revocations: [],
      joined: [
        {
          workspace: "ws-rig-only",
          workspace_name: "Rig Only WS",
          name: "pion-became-rig",
          peers: [],
          revocations: [],
          rig: {
            owner: "u-owner",
            owner_email: "owner@example.com",
            owner_name: "Owner",
            person: "a".repeat(64),
            at: Math.floor(Date.now() / 1000),
          },
        },
      ],
    }),
    { mode: 0o600 },
  );
  writeFileSync(join(data, "config.json"), JSON.stringify({ engine: "pion", driveRoots: [drive] }) + "\n");
  const wd = startWholeDaemon(bin, data);
  const exitCode = await wd.waitExit(12_000);
  assert.equal(exitCode, 0, `expected clean BecameRig stop exit 0, got ${exitCode}; stderr:\n${wd.stderr()}`);
  assert.ok(
    wd.stderr().includes("station became rig-only: triggering handover to rig process"),
    `expected BecameRig log message, got:\n${wd.stderr()}`,
  );
});

test("W16B.8: Control stream 1 idle exemption + live revocation kicks active stillfail/admin/1 connection immediately", { skip: process.platform === "win32" }, async () => {
  const addon = resolveMeshAddon();
  const { grantKeys, signMemberJwt } = makeGrantKeysAndSigner();
  const data = freshDir("rev-idle-data");
  const drive = freshDir("rev-idle-drive");
  const stSeed = randomBytes(32);
  const probe = await addon.bind({ secretKey: stSeed, alpns: [], relayUrls: [], discovery: false, dht: false, bindAddr: "127.0.0.1:0" });
  const stationId = probe.id();
  await probe.close();

  const memberEp = await addon.bind({
    secretKey: randomBytes(32),
    alpns: [ADMIN_ALPN],
    relayUrls: [],
    discovery: false,
    dht: false,
    bindAddr: "127.0.0.1:0",
  });
  endpoints.push(memberEp);

  const ws = "ws-rev-idle";
  let liveWsSock: import("ws").WebSocket | null = null;
  const wsHttp = createHttpServer((_req, res) => { res.writeHead(404); res.end(); });
  const wss = new WebSocketServer({ server: wsHttp });
  servers.push(wsHttp, wss);
  wss.on("connection", (sock) => {
    liveWsSock = sock;
  });
  await new Promise<void>((r) => wsHttp.listen(0, "127.0.0.1", () => r()));
  const wsPort = (wsHttp.address() as { port: number }).port;

  seedWholeDataDir(data, stSeed, stationId, memberEp.id(), drive, ws, grantKeys, `http://127.0.0.1:${wsPort}`);

  // Set generic peer-http idle sweep to 1000ms so any non-exempt stream idle > 1s is closed.
  const wd = startWholeDaemon(bin, data, { STILLFAIL_PEER_HTTP_IDLE_MS: "1000" });
  await until("ready", () => wd.messages.find((m) => m.ready === true));
  const meshAddr = await until("mesh bound", () => wd.meshAddr());
  await until("presence WS connected", () => liveWsSock !== null, 10_000);

  const nowSec = Math.floor(Date.now() / 1000);
  const jwt1 = signMemberJwt({
    ws,
    device: memberEp.id(),
    sub: "u-alice",
    email: "alice@example.com",
    name: "Alice",
    role: "owner",
    iat: nowSec - 10,
    exp: nowSec + 3600,
    sid: "sid-live-1",
  });
  const { conn: adminConn, ctrl, ctrlReader, helloReply } = await openAdminConn(memberEp, stationId, meshAddr, jwt1);
  assert.equal(helloReply?.ok, true, `admin hello failed: ${JSON.stringify(helloReply)}`);

  const st1 = await adminCall(adminConn, "GET", "/status");
  assert.equal(st1.status, 200);

  // R4 Item 6: Unauthenticated stream 1 (incomplete/no valid `hello`) MUST be closed by the 1000ms idle sweep,
  // while authenticated stream 1 is exempt and survives 1600ms idle + renewal!
  const unauthConn = await memberEp.connect({ id: stationId, relays: [], ips: [meshAddr] }, ADMIN_ALPN);
  const unauthCtrl = await unauthConn.openBi();
  // Write 1 partial byte so QUIC transmits the stream open frame to the server without completing hello.
  await unauthCtrl.write(Buffer.from("{"));

  // Sleep 1600ms (> 1000ms idle sweep) with BOTH streams idle:
  await new Promise((r) => setTimeout(r, 1600));

  // Unauthenticated stream 1 MUST have been closed/reset by idle sweep!
  let unauthClosed = false;
  try {
    const c = await Promise.race([
      unauthCtrl.read(),
      new Promise<string>((r) => setTimeout(() => r("timeout"), 1500)),
    ]);
    unauthClosed = c === null;
  } catch {
    unauthClosed = true;
  }
  assert.equal(unauthClosed, true, "unauthenticated stream 1 must be reaped by idle sweep");
  try { await unauthConn.close(0, "done"); } catch {}

  const jwt2 = signMemberJwt({
    ws,
    device: memberEp.id(),
    sub: "u-alice",
    email: "alice@example.com",
    name: "Alice",
    role: "owner",
    iat: nowSec - 5,
    exp: nowSec + 7200,
    sid: "sid-live-1",
  });
  await writeLine(ctrl, { credential: jwt2 });
  const renewReply = await ctrlReader.line();
  assert.equal(renewReply?.ok, true, `control stream 1 renewal after idle failed: ${JSON.stringify(renewReply)}`);
  const st2 = await adminCall(adminConn, "GET", "/status");
  assert.equal(st2.status, 200);

  // R3 Item 1a: Push live revocation via cloud presence `state` frame -> active connection
  // MUST be kicked immediately (`credential_revoked`), so subsequent GET /status fails!
  liveWsSock!.send(
    JSON.stringify({
      type: "state",
      workspace: ws,
      workspace_name: "Whole E2E WS",
      name: "pion-whole-e2e",
      peers: [{ id: memberEp.id(), name: "peer-station" }],
      revocations: [{ kind: "sub", id: "u-alice", at: nowSec + 60 }],
    }),
  );

  await until("active admin connection kicked after live revocation", async () => {
    try {
      await adminCall(adminConn, "GET", "/status", {}, undefined, 1500);
      return false;
    } catch {
      return true;
    }
  }, 8_000);

  try { await adminConn.close(0, "done"); } catch {}
  wd.sendCtrl({ op: "stop" });
  assert.equal(await wd.waitExit(), 0, wd.stderr());
});

test("W16B.9: Real personal lock (onPersonalLock) rejects app device removed from personal lock while admitting active device", { skip: process.platform === "win32" }, async () => {
  const addon = resolveMeshAddon();
  const { grantKeys, signMemberJwt } = makeGrantKeysAndSigner();
  const data = freshDir("person-lock-data");
  const drive = freshDir("person-lock-drive");
  const stSeed = randomBytes(32);
  const probe = await addon.bind({ secretKey: stSeed, alpns: [], relayUrls: [], discovery: false, dht: false, bindAddr: "127.0.0.1:0" });
  const stationId = probe.id();
  await probe.close();

  const epGood = await addon.bind({ secretKey: randomBytes(32), alpns: [ADMIN_ALPN], relayUrls: [], discovery: false, dht: false, bindAddr: "127.0.0.1:0" });
  const epRemoved = await addon.bind({ secretKey: randomBytes(32), alpns: [ADMIN_ALPN], relayUrls: [], discovery: false, dht: false, bindAddr: "127.0.0.1:0" });
  endpoints.push(epGood, epRemoved);

  const ws = "ws-person-lock";
  const edKey = () => {
    const { privateKey, publicKey } = generateKeyPairSync("ed25519");
    const hex = (publicKey.export({ format: "der", type: "spki" }) as Buffer).subarray(-32).toString("hex");
    return { hex, id: `ed25519:${hex}`, sign: (b: Buffer) => cryptoSign(null, b, privateKey).toString("hex") };
  };
  const signEntry = (e: Omit<Entry, "sig">, k: ReturnType<typeof edKey>): Entry =>
    ({ ...e, sig: { key: k.id, alg: "Ed25519", sig: k.sign(signedBytes(entryHash(e as Entry))) } }) as Entry;

  const firstDev = { signer: edKey(), base: edKey(), pkey: edKey() };
  const removedDev = { signer: edKey(), base: edKey(), pkey: edKey() };

  // Build personal lock chain for u-alice: genesis(firstDev) -> add(removedDev) -> device.remove(removedDev)
  const personalChain: Entry[] = [];
  const pushP = (arr: Entry[], kind: string, body: unknown, by: ReturnType<typeof edKey>) => {
    const last = arr[arr.length - 1];
    arr.push(
      signEntry({ v: 1, ws: "person:u-alice", seq: arr.length, prev: last ? entryHash(last) : null, at: 1000, kind, body }, by),
    );
  };
  pushP(personalChain, "genesis", { sub: "u-alice", device: { key: firstDev.pkey.id, id: firstDev.base.hex, label: "first" } }, firstDev.pkey);
  pushP(personalChain, "device", { key: removedDev.pkey.id, id: removedDev.base.hex, label: "removed" }, firstDev.pkey);
  // R4 Item 1a: Fork BEFORE `device.remove` with 5 entries (longer than the 3-entry kept chain!) signed by removedDev:
  // `lock::person_chain` removal rule MUST beat the longer pre-removal fork!
  const longerFork: Entry[] = [...personalChain];
  for (let fi = 0; fi < 3; fi++) {
    const dummy = edKey();
    pushP(longerFork, "device", { key: dummy.id, id: edKey().hex, label: `fork-${fi}` }, removedDev.pkey);
  }
  assert.equal(longerFork.length, 5);
  pushP(personalChain, "device.remove", { key: removedDev.pkey.id }, firstDev.pkey);
  assert.equal(personalChain.length, 3);
  const personGenesis = entryHash(personalChain[0]!);

  // Build workspace lock chain with BOTH firstDev and removedDev in workspace lock, AND bind u-alice -> personGenesis
  const wsGen = signEntry(
    {
      v: 1,
      ws,
      seq: 0,
      prev: null,
      at: 1000,
      kind: "genesis",
      body: {
        owner: "u-alice",
        origins: ["https://app.still.fail"],
        rp_id: "app.still.fail",
        cloud_keys: grantKeys,
        members: [{ sub: "u-alice", email: "alice@example.com", role: "owner" }],
        devices: [
          { id: firstDev.base.hex, sub: "u-alice", kind: "app", label: "first", sign_key: firstDev.signer.id },
          { id: removedDev.base.hex, sub: "u-alice", kind: "app", label: "removed", sign_key: removedDev.signer.id },
        ],
        passkeys: [],
        stations: [{ key: stationId, name: "pion-whole-e2e" }],
        gateways: [],
      },
    },
    firstDev.signer,
  );
  const wsState0 = lockGenesis(wsGen);
  const wsBind = signEntry(
    { v: 1, ws, seq: 1, prev: wsState0.head, at: 1001, kind: "person", body: { sub: "u-alice", person: personGenesis } },
    firstDev.signer,
  );
  // Sanity-check our signed entries fold cleanly in shared/lock.ts
  const wsState1 = lockApply(wsState0, wsBind, 2000);
  assert.equal(wsState1.persons.get("u-alice"), personGenesis);

  seedWholeDataDir(data, stSeed, stationId, epGood.id(), drive, ws, grantKeys);
  writeFileSync(join(data, "mesh/lock.json"), JSON.stringify({ entries: [wsGen, wsBind] }), { mode: 0o600 });
  writeFileSync(join(data, "mesh/person-chains.json"), JSON.stringify({ chains: { [personGenesis]: personalChain } }), { mode: 0o600 });

  const wd = startWholeDaemon(bin, data);
  await until("ready", () => wd.messages.find((m) => m.ready === true));
  const meshAddr = await until("mesh bound", () => wd.meshAddr());

  // 1a. removedDev brings a LONGER 5-entry pre-removal fork -> MUST BE REFUSED at hello (`lock::person_chain`)!
  const jwtRemoved = signMemberJwt({ ws, device: epRemoved.id(), sub: "u-alice", email: "alice@example.com", name: "Alice", role: "owner" });
  const badForkRes = await openAdminConn(epRemoved, stationId, meshAddr, jwtRemoved, {
    device: removedDev.base.hex,
    proof: removedDev.base.sign(endpointBytes(ws, epRemoved.id())),
    person: longerFork,
  });
  assert.ok(badForkRes.helloReply?.error, `removed device with longer 5-entry fork MUST be refused at hello, got: ${JSON.stringify(badForkRes.helloReply)}`);
  await badForkRes.conn.close(0, "done");

  // 1b. firstDev is on BOTH workspace lock AND personal lock -> MUST BE ADMITTED!
  const jwtGood = signMemberJwt({ ws, device: epGood.id(), sub: "u-alice", email: "alice@example.com", name: "Alice", role: "owner" });
  const goodRes = await openAdminConn(epGood, stationId, meshAddr, jwtGood, {
    device: firstDev.base.hex,
    proof: firstDev.base.sign(endpointBytes(ws, epGood.id())),
  });
  assert.equal(goodRes.helloReply?.ok, true, `device on personal lock should be admitted, got: ${JSON.stringify(goodRes.helloReply)}`);
  const st = await adminCall(goodRes.conn, "GET", "/status");
  assert.equal(st.status, 200);
  await goodRes.conn.close(0, "done");

  wd.sendCtrl({ op: "stop" });
  assert.equal(await wd.waitExit(), 0, wd.stderr());

  // R4 Item 1b: Fresh station with NO cached `person-chains.json` yet!
  // Valid app device brings signed `hello.lock.person` -> hello `ok: true`, immediate `GET /status -> 200`,
  // AND chain is persisted to `<data>/mesh/person-chains.json`!
  const data2 = freshDir("person-lock-uncached");
  seedWholeDataDir(data2, stSeed, stationId, epGood.id(), drive, ws, grantKeys);
  writeFileSync(join(data2, "mesh/lock.json"), JSON.stringify({ entries: [wsGen, wsBind] }), { mode: 0o600 });
  assert.equal(existsSync(join(data2, "mesh/person-chains.json")), false);

  const wd2 = startWholeDaemon(bin, data2);
  await until("ready uncached", () => wd2.messages.find((m) => m.ready === true));
  const meshAddr2 = await until("mesh bound uncached", () => wd2.meshAddr());

  const firstBring = await openAdminConn(epGood, stationId, meshAddr2, jwtGood, {
    device: firstDev.base.hex,
    proof: firstDev.base.sign(endpointBytes(ws, epGood.id())),
    person: personalChain,
  });
  assert.equal(firstBring.helloReply?.ok, true, `uncached personal lock hello failed: ${JSON.stringify(firstBring.helloReply)}`);
  const stUncached = await adminCall(firstBring.conn, "GET", "/status");
  assert.equal(stUncached.status, 200, "immediate GET /status after bringing uncached personal lock must return 200");
  assert.equal(existsSync(join(data2, "mesh/person-chains.json")), true, "personal lock chain must be persisted to person-chains.json");
  await firstBring.conn.close(0, "done");

  wd2.sendCtrl({ op: "stop" });
  assert.equal(await wd2.waitExit(), 0, wd2.stderr());

  // R5 Item 3: Transactional persistence of personal lock chain — block `mesh/person-chains.json`
  // as a directory so `save_person_chains()` fails -> `hello` MUST be refused (`ok !== true`) and dir stays empty!
  const data3 = freshDir("person-lock-persist-fail");
  seedWholeDataDir(data3, stSeed, stationId, epGood.id(), drive, ws, grantKeys);
  writeFileSync(join(data3, "mesh/lock.json"), JSON.stringify({ entries: [wsGen, wsBind] }), { mode: 0o600 });
  mkdirSync(join(data3, "mesh/person-chains.json"), { recursive: true });

  const wd3 = startWholeDaemon(bin, data3);
  await until("ready persist-fail", () => wd3.messages.find((m) => m.ready === true));
  const meshAddr3 = await until("mesh bound persist-fail", () => wd3.meshAddr());
  const failPersistRes = await openAdminConn(epGood, stationId, meshAddr3, jwtGood, {
    device: firstDev.base.hex,
    proof: firstDev.base.sign(endpointBytes(ws, epGood.id())),
    person: personalChain,
  });
  assert.notEqual(failPersistRes.helloReply?.ok, true, `hello MUST fail when person-chains.json cannot persist, got: ${JSON.stringify(failPersistRes.helloReply)}`);
  assert.equal(readdirSync(join(data3, "mesh/person-chains.json")).length, 0);
  await failPersistRes.conn.close(0, "done");
  wd3.sendCtrl({ op: "stop" });
  assert.equal(await wd3.waitExit(), 0, wd3.stderr());
});

test("W16B.10: Per-workspace Drive isolation (joined workspace own root 200, empty 403, relative path rejected) + Drive upload atomic protection (fixed CL & no-CL overflow)", { skip: process.platform === "win32" }, async () => {
  const addon = resolveMeshAddon();
  const { grantKeys, signMemberJwt } = makeGrantKeysAndSigner();
  const data = freshDir("drive-iso-data");
  const homeDrive = freshDir("drive-iso-home");
  const joinedOwnDrive = freshDir("drive-iso-joined-own");
  const stSeed = randomBytes(32);
  const probe = await addon.bind({ secretKey: stSeed, alpns: [], relayUrls: [], discovery: false, dht: false, bindAddr: "127.0.0.1:0" });
  const stationId = probe.id();
  await probe.close();

  const epHome = await addon.bind({ secretKey: randomBytes(32), alpns: [ADMIN_ALPN], relayUrls: [], discovery: false, dht: false, bindAddr: "127.0.0.1:0" });
  const epJoinedEmpty = await addon.bind({ secretKey: randomBytes(32), alpns: [ADMIN_ALPN], relayUrls: [], discovery: false, dht: false, bindAddr: "127.0.0.1:0" });
  const epJoinedOwn = await addon.bind({ secretKey: randomBytes(32), alpns: [ADMIN_ALPN], relayUrls: [], discovery: false, dht: false, bindAddr: "127.0.0.1:0" });
  endpoints.push(epHome, epJoinedEmpty, epJoinedOwn);

  const wsHome = "ws-home-drive";
  const wsJoinedEmpty = "ws-joined-empty";
  const wsJoinedOwn = "ws-joined-own";
  mkdirSync(join(data, "mesh"), { recursive: true });
  mkdirSync(join(data, "run"), { recursive: true });
  mkdirSync(homeDrive, { recursive: true });
  mkdirSync(joinedOwnDrive, { recursive: true });
  writeFileSync(join(homeDrive, "secret.txt"), "HOME-SECRET-ONLY");
  writeFileSync(join(homeDrive, "existing.bin"), "ORIGINAL-DATA-MUST-STAY");
  writeFileSync(join(joinedOwnDrive, "own.txt"), "JOINED8!");

  writeFileSync(join(data, "mesh/secret.key"), stSeed, { mode: 0o600 });
  writeFileSync(
    join(data, "mesh/cloud.json"),
    JSON.stringify({
      origin: "",
      station: stationId,
      workspace: wsHome,
      workspace_name: "Home WS",
      name: "pion-drive-iso",
      relay_url: "",
      relay_urls: [],
      grant_keys: grantKeys,
      peers: [],
      revocations: [],
      joined: [
        {
          workspace: wsJoinedEmpty,
          workspace_name: "Joined Empty Drive WS",
          name: "pion-drive-iso",
          grant_keys: grantKeys,
          peers: [],
          revocations: [],
        },
        {
          workspace: wsJoinedOwn,
          workspace_name: "Joined Own Drive WS",
          name: "pion-drive-iso",
          grant_keys: grantKeys,
          peers: [],
          revocations: [],
        },
      ],
    }),
    { mode: 0o600 },
  );
  writeFileSync(
    join(data, "config.json"),
    JSON.stringify({
      engine: "pion",
      drive: {
        roots: [homeDrive, "relative/ignored-root"],
        workspaces: {
          [wsJoinedEmpty]: [],
          [wsJoinedOwn]: [joinedOwnDrive, "relative/joined-ignored", "\\win-slash", "C:\\win-drive"],
        },
      },
    }) + "\n",
  );

  const wd = startWholeDaemon(bin, data);
  await until("ready", () => wd.messages.find((m) => m.ready === true));
  const meshAddr = await until("mesh bound", () => wd.meshAddr());
  await until("DB open", () => existsSync(join(data, "stillfail.db")), 10_000);

  // 1a. Joined workspace `wsJoinedOwn` with its OWN root (NOT in home `drive.roots`) MUST read its 8-byte file with 200!
  const jwtJoinedOwn = signMemberJwt({ ws: wsJoinedOwn, device: epJoinedOwn.id(), sub: "u-carol", email: "carol@example.com", name: "Carol", role: "owner" });
  const jOwnConn = await openAdminConn(epJoinedOwn, stationId, meshAddr, jwtJoinedOwn);
  assert.equal(jOwnConn.helloReply?.ok, true, JSON.stringify(jOwnConn.helloReply));
  const rOwnOk = await adminCall(jOwnConn.conn, "GET", `/drive/read?root=${encodeURIComponent(joinedOwnDrive)}&path=own.txt&offset=0&length=64`);
  assert.equal(rOwnOk.status, 200, `joined ws own root must return 200, got ${rOwnOk.status}: ${rOwnOk.body.toString("utf8")}`);
  assert.equal(rOwnOk.body.toString("utf8"), "JOINED8!");
  const rOwnRel = await adminCall(jOwnConn.conn, "GET", `/drive/read?root=${encodeURIComponent("relative/joined-ignored")}&path=own.txt&offset=0&length=64`);
  assert.equal(rOwnRel.status, 403, `relative drive root must be rejected with 403, got ${rOwnRel.status}`);
  const rWinSlash = await adminCall(jOwnConn.conn, "GET", `/drive/read?root=${encodeURIComponent("\\win-slash")}&path=own.txt&offset=0&length=64`);
  assert.equal(rWinSlash.status, 403, `Unix host must reject backslash root with 403, got ${rWinSlash.status}`);
  const rWinDrive = await adminCall(jOwnConn.conn, "GET", `/drive/read?root=${encodeURIComponent("C:\\win-drive")}&path=own.txt&offset=0&length=64`);
  assert.equal(rWinDrive.status, 403, `Unix host must reject Windows drive-letter root with 403, got ${rWinDrive.status}`);
  await jOwnConn.conn.close(0, "done");

  // 1b. Joined workspace with empty drive.workspaces[wsJoinedEmpty] = [] MUST get 403 for homeDrive, $HOME, and empty root!
  const jwtJoined = signMemberJwt({ ws: wsJoinedEmpty, device: epJoinedEmpty.id(), sub: "u-bob", email: "bob@example.com", name: "Bob", role: "owner" });
  const jConn = await openAdminConn(epJoinedEmpty, stationId, meshAddr, jwtJoined);
  assert.equal(jConn.helloReply?.ok, true, JSON.stringify(jConn.helloReply));
  const rHomeRoot = await adminCall(jConn.conn, "GET", `/drive/read?root=${encodeURIComponent(homeDrive)}&path=secret.txt&offset=0&length=64`);
  assert.equal(rHomeRoot.status, 403, `joined ws must NOT read home drive root, got ${rHomeRoot.status}`);
  const rOsHome = await adminCall(jConn.conn, "GET", `/drive/read?root=${encodeURIComponent(homedir())}&path=.profile&offset=0&length=64`);
  assert.equal(rOsHome.status, 403, `joined ws must NOT fallback to OS $HOME, got ${rOsHome.status}`);
  const rEmptyRoot = await adminCall(jConn.conn, "GET", `/drive/read?path=secret.txt&offset=0&length=64`);
  assert.equal(rEmptyRoot.status, 403, `joined ws with empty roots must refuse empty root, got ${rEmptyRoot.status}`);
  await jConn.conn.close(0, "done");

  // 2. Home workspace member CAN read homeDrive, and both fixed-CL AND no-CL overflow uploads return 400 WITHOUT overwriting existing.bin!
  const jwtHome = signMemberJwt({ ws: wsHome, device: epHome.id(), sub: "u-alice", email: "alice@example.com", name: "Alice", role: "owner" });
  const hConn = await openAdminConn(epHome, stationId, meshAddr, jwtHome);
  assert.equal(hConn.helloReply?.ok, true, JSON.stringify(hConn.helloReply));

  const rOk = await adminCall(hConn.conn, "GET", `/drive/read?root=${encodeURIComponent(homeDrive)}&path=secret.txt&offset=0&length=64`);
  assert.equal(rOk.status, 200);
  assert.equal(rOk.body.toString("utf8"), "HOME-SECRET-ONLY");

  // Over-length body (Content-Length: 10, sends 12 bytes) -> 400, existing.bin untouched!
  const upOver = await adminCall(
    hConn.conn,
    "PUT",
    `/drive/upload?root=${encodeURIComponent(homeDrive)}&path=existing.bin&id=up-over&offset=0&total=10&replace=1`,
    { "content-type": "application/octet-stream", "content-length": "10" },
    Buffer.from("0123456789XX"),
  );
  assert.equal(upOver.status, 400, `over-length upload must return 400, got ${upOver.status}: ${upOver.body.toString("utf8")}`);
  assert.equal(readFileSync(join(homeDrive, "existing.bin"), "utf8"), "ORIGINAL-DATA-MUST-STAY");

  // Under-length body (Content-Length: 10, sends 8 bytes) -> 400, existing.bin untouched!
  const upUnder = await adminCall(
    hConn.conn,
    "PUT",
    `/drive/upload?root=${encodeURIComponent(homeDrive)}&path=existing.bin&id=up-under&offset=0&total=10&replace=1`,
    { "content-type": "application/octet-stream", "content-length": "10" },
    Buffer.from("01234567"),
  );
  assert.equal(upUnder.status, 400, `under-length upload must return 400, got ${upUnder.status}: ${upUnder.body.toString("utf8")}`);
  assert.equal(readFileSync(join(homeDrive, "existing.bin"), "utf8"), "ORIGINAL-DATA-MUST-STAY");

  // Out-of-bounds offset + Content-Length > total (6 + 8 > 10) -> 400, existing.bin untouched!
  const upOob = await adminCall(
    hConn.conn,
    "PUT",
    `/drive/upload?root=${encodeURIComponent(homeDrive)}&path=existing.bin&id=up-oob&offset=6&total=10&replace=1`,
    { "content-type": "application/octet-stream", "content-length": "8" },
    Buffer.from("01234567"),
  );
  assert.equal(upOob.status, 400, `offset+content-length>total must return 400, got ${upOob.status}`);
  assert.equal(readFileSync(join(homeDrive, "existing.bin"), "utf8"), "ORIGINAL-DATA-MUST-STAY");

  // R4 Item 8: NO `Content-Length` upload sending `total + 2` (12 bytes for total=10) -> 400, existing.bin untouched!
  const upNoClOver = await adminCall(
    hConn.conn,
    "PUT",
    `/drive/upload?root=${encodeURIComponent(homeDrive)}&path=existing.bin&id=up-nocl-over&offset=0&total=10&replace=1`,
    { "content-type": "application/octet-stream" },
    Buffer.from("0123456789XX"),
  );
  assert.equal(upNoClOver.status, 400, `no-CL upload sending total+2 bytes must return 400, got ${upNoClOver.status}`);
  assert.equal(readFileSync(join(homeDrive, "existing.bin"), "utf8"), "ORIGINAL-DATA-MUST-STAY");

  await hConn.conn.close(0, "done");
  wd.sendCtrl({ op: "stop" });
  assert.equal(await wd.waitExit(), 0, wd.stderr());
});

test("W16B.11: Corrupt snapshot fails takeover while preserved on disk + real launcher snapshot write failure produces handoff-failed", { skip: process.platform === "win32" }, async () => {
  const launcher = resolveLauncherBinary();
  const readerBin = resolveReaderBinary();
  const addon = resolveMeshAddon();
  const { grantKeys } = makeGrantKeysAndSigner();

  // Part A: Corrupt `run/whole-handover.json` -> daemon emits `failed`, does NOT open DB, preserves corrupt file!
  const dataCorrupt = freshDir("ho-corrupt-data");
  const driveCorrupt = freshDir("ho-corrupt-drive");
  const stSeed = randomBytes(32);
  const probe = await addon.bind({ secretKey: stSeed, alpns: [], relayUrls: [], discovery: false, dht: false, bindAddr: "127.0.0.1:0" });
  const stationId = probe.id();
  await probe.close();

  seedWholeDataDir(dataCorrupt, stSeed, stationId, stationId, driveCorrupt, "ws-corrupt", grantKeys);
  mkdirSync(join(dataCorrupt, "run"), { recursive: true });
  writeFileSync(join(dataCorrupt, "run/whole-handover.json"), "{corrupt-handover-json");

  const wdCorrupt = startWholeDaemon(bin, dataCorrupt);
  await until("failed message emitted for corrupt snapshot", () => wdCorrupt.messages.find((m) => typeof m.failed === "string"), 10_000);
  await wdCorrupt.waitExit(10_000);
  assert.equal(existsSync(join(dataCorrupt, "run/whole-handover.json")), true, "corrupt whole-handover.json must be preserved on disk");
  assert.equal(existsSync(join(dataCorrupt, "stillfail.db")), false, "SQLite DB must not open on corrupt handover snapshot");

  // Part B: Real Rust Launcher `SIGUSR2` handover where `run/whole-handover.json` is blocked (pre-created directory)
  // -> predecessor carries `handoverFailed` -> successor emits `failed` before `taken` -> launcher writes `handoff-failed`!
  const app = freshDir("ho-fail-app");
  const data = freshDir("ho-fail-data");
  const drive = freshDir("ho-fail-drive");
  mkdirSync(join(app, "station"), { recursive: true });
  copyFileSync(readerBin, join(app, "station", "stillfail-reader"));
  chmodSync(join(app, "station", "stillfail-reader"), 0o755);
  writeFileSync(join(app, "station", "main.js"), "process.exit(99);\n");
  writeFileSync(join(app, "BUILD"), "9916\n");
  const installedPion = join(app, "station", "stillfail-station-pion");
  copyFileSync(bin, installedPion);
  chmodSync(installedPion, 0o755);

  const frontPort = await pickFreeUdpPort();
  seedWholeDataDir(data, stSeed, stationId, stationId, drive, "ws-ho-fail", grantKeys);
  let logs = "";
  const lc = spawn(launcher, ["run", "--app", app, "--data", data], {
    stdio: ["ignore", "pipe", "pipe"],
    env: {
      ...process.env,
      STILLFAIL_NODE: process.execPath,
      STILLFAIL_MB_READER: join(app, "station", "stillfail-reader"),
      STILLFAIL_STATION_PION: installedPion,
      STILLFAIL_STATION_ENGINE: "pion",
      STILLFAIL_STATION_ENGINE_STRICT: "1",
      STILLFAIL_NO_DISCOVERY: "1",
      STILLFAIL_NO_DHT: "1",
      STILLFAIL_MESH_BIND_ADDR: `127.0.0.1:${frontPort}`,
    },
  });
  children.push(lc);
  lc.stdout?.on("data", (d) => { logs += d.toString("utf8"); });
  lc.stderr?.on("data", (d) => { logs += d.toString("utf8"); });

  const readHubPid = () => {
    try {
      const j = JSON.parse(readFileSync(join(data, "run/hub.json"), "utf8"));
      return typeof j.pid === "number" && j.pid > 0 ? j.pid : null;
    } catch { return null; }
  };
  const pid1 = await until("pid1 ready", () => readHubPid(), 15_000);
  await until("DB open before blocking handover path", () => existsSync(join(data, "stillfail.db")), 10_000);
  // R5 Item 6: Wait until launcher logs confirm `pid1` has taken over before triggering `SIGUSR2`!
  await until(`launcher confirms Node ${pid1} has taken over`, () => logs.includes(`Node ${pid1} has taken over`), 15_000);

  // Block `run/whole-handover.json` by creating a directory at that exact path so `write_private` fails!
  mkdirSync(join(data, "run/whole-handover.json"), { recursive: true });
  process.kill(lc.pid!, "SIGUSR2");

  await until("launcher writes run/handoff-failed", () => existsSync(join(data, "run/handoff-failed")), 15_000);
  const pid2Match = /handover: Pion (\d+) started beside/.exec(logs);
  assert.ok(pid2Match, `expected successor pid2 in launcher logs; logs:\n${logs}`);
  const pid2Num = Number(pid2Match![1]);
  assert.notEqual(pid2Num, pid1);
  assert.ok(logs.includes(`Node ${pid1} has taken over`), `expected pid1 taken over; logs:\n${logs}`);
  assert.ok(logs.includes(`Node ${pid2Num} did not take over`), `expected successor Node ${pid2Num} did not take over; logs:\n${logs}`);
  assert.equal(logs.includes(`Node ${pid2Num} has taken over`), false, `successor Node ${pid2Num} MUST NOT take over; logs:\n${logs}`);

  lc.kill("SIGTERM");
  await new Promise((r) => lc.once("exit", () => r(undefined)));
  await until("pid1 exited", () => !isAlive(pid1), 10_000);
});

test("W16B.12: Live connection role downgrade via signed workspace lock takes effect immediately (POST -> 403, GET -> 200)", { skip: process.platform === "win32" }, async () => {
  const addon = resolveMeshAddon();
  const { grantKeys, signMemberJwt } = makeGrantKeysAndSigner();
  const data = freshDir("role-down-data");
  const drive = freshDir("role-down-drive");
  const stSeed = randomBytes(32);
  const probe = await addon.bind({ secretKey: stSeed, alpns: [], relayUrls: [], discovery: false, dht: false, bindAddr: "127.0.0.1:0" });
  const stationId = probe.id();
  await probe.close();

  const epBob = await addon.bind({ secretKey: randomBytes(32), alpns: [ADMIN_ALPN], relayUrls: [], discovery: false, dht: false, bindAddr: "127.0.0.1:0" });
  endpoints.push(epBob);

  const ws = "ws-role-down";
  const edKey = () => {
    const { privateKey, publicKey } = generateKeyPairSync("ed25519");
    const hex = (publicKey.export({ format: "der", type: "spki" }) as Buffer).subarray(-32).toString("hex");
    return { hex, id: `ed25519:${hex}`, sign: (b: Buffer) => cryptoSign(null, b, privateKey).toString("hex") };
  };
  const signEntry = (e: Omit<Entry, "sig">, k: ReturnType<typeof edKey>): Entry =>
    ({ ...e, sig: { key: k.id, alg: "Ed25519", sig: k.sign(signedBytes(entryHash(e as Entry))) } }) as Entry;

  const alice = { signer: edKey(), base: edKey() };
  const bob = { signer: edKey(), base: edKey() };

  const wsGen = signEntry(
    {
      v: 1,
      ws,
      seq: 0,
      prev: null,
      at: 1000,
      kind: "genesis",
      body: {
        owner: "u-alice",
        origins: ["https://app.still.fail"],
        rp_id: "app.still.fail",
        cloud_keys: grantKeys,
        members: [
          { sub: "u-alice", email: "alice@example.com", role: "owner" },
          { sub: "u-bob", email: "bob@example.com", role: "admin" },
        ],
        devices: [
          { id: alice.base.hex, sub: "u-alice", kind: "app", label: "alice", sign_key: alice.signer.id },
          { id: bob.base.hex, sub: "u-bob", kind: "app", label: "bob", sign_key: bob.signer.id },
        ],
        passkeys: [],
        stations: [{ key: stationId, name: "pion-role-down" }],
        gateways: [],
      },
    },
    alice.signer,
  );
  const wsState0 = lockGenesis(wsGen);
  const wsDowngrade = signEntry(
    {
      v: 1,
      ws,
      seq: 1,
      prev: wsState0.head,
      at: 1001,
      kind: "member",
      body: { sub: "u-bob", email: "bob@example.com", role: "viewer" },
    },
    alice.signer,
  );
  const wsState1 = lockApply(wsState0, wsDowngrade, 2000);
  assert.equal(wsState1.members.get("u-bob")?.role, "viewer");

  let liveWsSock: import("ws").WebSocket | null = null;
  const wsHttp = createHttpServer((_req, res) => { res.writeHead(404); res.end(); });
  const wss = new WebSocketServer({ server: wsHttp });
  servers.push(wsHttp, wss);
  wss.on("connection", (sock) => { liveWsSock = sock; });
  await new Promise<void>((r) => wsHttp.listen(0, "127.0.0.1", () => r()));
  const wsPort = (wsHttp.address() as { port: number }).port;

  seedWholeDataDir(data, stSeed, stationId, epBob.id(), drive, ws, grantKeys, `http://127.0.0.1:${wsPort}`);
  writeFileSync(join(data, "mesh/lock.json"), JSON.stringify({ entries: [wsGen] }), { mode: 0o600 });

  const wd = startWholeDaemon(bin, data);
  await until("ready", () => wd.messages.find((m) => m.ready === true));
  const meshAddr = await until("mesh bound", () => wd.meshAddr());
  await until("presence WS connected", () => liveWsSock !== null, 10_000);

  // Bob connects as `admin` and creates a session -> 200!
  const jwtBob = signMemberJwt({ ws, device: epBob.id(), sub: "u-bob", email: "bob@example.com", name: "Bob", role: "admin" });
  const { conn: bobConn, helloReply } = await openAdminConn(epBob, stationId, meshAddr, jwtBob, {
    device: bob.base.hex,
    proof: bob.base.sign(endpointBytes(ws, epBob.id())),
  });
  assert.equal(helloReply?.ok, true, JSON.stringify(helloReply));
  assert.equal(helloReply?.role, "admin");

  const writeBefore = await adminCall(
    bobConn,
    "POST",
    "/sessions",
    { "content-type": "application/json" },
    Buffer.from(JSON.stringify({ key: "before-downgrade", title: "Allowed" })),
  );
  assert.equal(writeBefore.status, 200, `admin write before downgrade must succeed, got ${writeBefore.status}`);

  // Push signed lock update downgrading Bob -> `viewer` via live presence WS!
  liveWsSock!.send(JSON.stringify({ type: "lock", entries: [wsGen, wsDowngrade] }));

  // Immediately on the SAME live connection: POST /sessions MUST return 403 while GET /status returns 200!
  await until("live connection downgraded to viewer (POST /sessions -> 403)", async () => {
    const r = await adminCall(
      bobConn,
      "POST",
      "/sessions",
      { "content-type": "application/json" },
      Buffer.from(JSON.stringify({ key: "after-downgrade", title: "Denied" })),
      2_000,
    );
    return r.status === 403;
  }, 8_000).catch((e) => {
    throw new Error(`${(e as Error).message}\nstderr:\n${wd.stderr()}`);
  });

  const readAfter = await adminCall(bobConn, "GET", "/status");
  assert.equal(readAfter.status, 200, `viewer GET /status must still return 200, got ${readAfter.status}`);

  await bobConn.close(0, "done");
  wd.sendCtrl({ op: "stop" });
  assert.equal(await wd.waitExit(), 0, wd.stderr());
});

test("W16B.13: ACID adopted-runners.db — (a) pre-ACKed real stillfail-runner + 2nd SIGUSR2, (b) restarted runner instance isolation, (c) DB failure fail-stop ACK, (d) split UTF-8 coalescing", { skip: process.platform === "win32" }, async () => {
  const launcher = resolveLauncherBinary();
  const readerBin = resolveReaderBinary();
  const runnerBin = resolveRunnerBinary();
  const addon = resolveMeshAddon();
  const { grantKeys, signMemberJwt } = makeGrantKeysAndSigner();

  const app = freshDir("r7-runner-app");
  const data = freshDir("r7-runner-data");
  const drive = freshDir("r7-runner-drive");
  mkdirSync(join(app, "station"), { recursive: true });
  copyFileSync(readerBin, join(app, "station", "stillfail-reader"));
  chmodSync(join(app, "station", "stillfail-reader"), 0o755);
  writeFileSync(join(app, "station", "main.js"), "process.exit(99);\n");
  writeFileSync(join(app, "BUILD"), "9916\n");

  const installedPion = join(app, "station", "stillfail-station-pion");
  copyFileSync(bin, installedPion);
  chmodSync(installedPion, 0o755);

  const stSeed = randomBytes(32);
  const probe = await addon.bind({ secretKey: stSeed, alpns: [], relayUrls: [], discovery: false, dht: false, bindAddr: "127.0.0.1:0" });
  const stationId = probe.id();
  await probe.close();

  const memberEp = await addon.bind({
    secretKey: randomBytes(32),
    alpns: [ADMIN_ALPN],
    relayUrls: [],
    discovery: false,
    dht: false,
    bindAddr: "127.0.0.1:0",
  });
  endpoints.push(memberEp);

  const ws = "ws-r7-runner";
  const frontPort = await pickFreeUdpPort();
  seedWholeDataDir(data, stSeed, stationId, memberEp.id(), drive, ws, grantKeys);

  let logs = "";
  const lc = spawn(launcher, ["run", "--app", app, "--data", data], {
    stdio: ["ignore", "pipe", "pipe"],
    env: {
      ...process.env,
      STILLFAIL_NODE: process.execPath,
      STILLFAIL_MB_READER: join(app, "station", "stillfail-reader"),
      STILLFAIL_STATION_PION: installedPion,
      STILLFAIL_STATION_ENGINE: "pion",
      STILLFAIL_STATION_ENGINE_STRICT: "1",
      STILLFAIL_NO_DISCOVERY: "1",
      STILLFAIL_NO_DHT: "1",
      STILLFAIL_MESH_BIND_ADDR: `127.0.0.1:${frontPort}`,
    },
  });
  children.push(lc);
  lc.stdout?.on("data", (d) => { logs += d.toString("utf8"); });
  lc.stderr?.on("data", (d) => { logs += d.toString("utf8"); });
  const lcExit = new Promise<number | null>((resolve) => lc.once("exit", (code) => resolve(code)));

  const readHubPid = () => {
    try {
      const j = JSON.parse(readFileSync(join(data, "run/hub.json"), "utf8"));
      return typeof j.pid === "number" && j.pid > 0 ? j.pid : null;
    } catch { return null; }
  };
  const pid1 = await until("r7 pid1 ready", () => readHubPid(), 15_000);
  await until(`launcher confirms Node ${pid1} has taken over`, () => logs.includes(`Node ${pid1} has taken over`), 15_000);

  const frontAddr = `127.0.0.1:${frontPort}`;
  const memberJwt = signMemberJwt({ ws, device: memberEp.id(), sub: "u-alice", email: "alice@example.com", name: "Alice", role: "owner" });

  // Create 4 sessions for (a) real pre-ACKed runner + Pion->Node->Pion, (b) restarted runner A->B,
  // (d) interleaved stdout/stderr split UTF-8, and (e) 2.25 MiB (>2 MiB) backpressured AdminApi response.
  const { conn: adminConn1, helloReply: hello1 } = await openAdminConn(memberEp, stationId, frontAddr, memberJwt);
  assert.equal(hello1?.ok, true, JSON.stringify(hello1));
  for (const [key, title] of [
    ["sess-r7-real", "R7 Real Runner"],
    ["sess-r7-restart", "R7 Restarted Runner"],
    ["sess-r7-utf8", "R7 Split UTF-8"],
    ["sess-r8-big", "R8 2.25 MiB Runner"],
    ["sess-r9-small", "R9 4097 Small Frames"],
  ]) {
    const r = await adminCall(
      adminConn1,
      "POST",
      "/sessions",
      { "content-type": "application/json" },
      Buffer.from(JSON.stringify({ key, title })),
    );
    assert.equal(r.status, 200, r.body.toString("utf8"));
  }
  await adminConn1.close(0, "done");

  const runnersDir = join(data, "run", "runners");
  mkdirSync(runnersDir, { recursive: true });

  // (a) Spawn REAL release `stillfail-runner` that writes:
  //   1) 23 bytes before 1st handover (consumed & ACKed by simulated predecessor Node),
  //   2) 15 bytes after 1st handover (consumed & ACKed by Pion #2 -> out=38),
  //   3) 14 bytes during simulated Pion->Node rollback (consumed & ACKed by Node -> out=52),
  //   4) 14 bytes after 2nd handover back to Pion #3 (consumed & ACKed by Pion #3 -> out=66).
  const preText = "predecessor-acked-23-b\n";
  const postText = "post-pion-15-b\n";
  const midNodeText = "mid-node-14-b\n";
  const afterPion3Text = "after-pion3-x\n";
  assert.equal(Buffer.byteLength(preText, "utf8"), 23);
  assert.equal(Buffer.byteLength(postText, "utf8"), 15);
  assert.equal(Buffer.byteLength(midNodeText, "utf8"), 14);
  assert.equal(Buffer.byteLength(afterPion3Text, "utf8"), 14);
  const triggerFile = join(data, "emit-post-15.flag");
  const triggerNodeFile = join(data, "emit-node-14.flag");
  const triggerPion3File = join(data, "emit-pion3-14.flag");
  const runnerReady = await new Promise<{ runner: number; pid: number; pgid: number; socket: string }>((resolve, reject) => {
    const rproc = spawn(
      runnerBin,
      [
        "--dir", runnersDir,
        "--id", "claude-sess-r7-real",
        "--cwd", data,
        "--",
        "/bin/sh", "-c",
        `printf 'predecessor-acked-23-b\\n'; ` +
        `while [ ! -f ${JSON.stringify(triggerFile)} ]; do sleep 0.05; done; printf 'post-pion-15-b\\n'; ` +
        `while [ ! -f ${JSON.stringify(triggerNodeFile)} ]; do sleep 0.05; done; printf 'mid-node-14-b\\n'; ` +
        `while [ ! -f ${JSON.stringify(triggerPion3File)} ]; do sleep 0.05; done; printf 'after-pion3-x\\n'; sleep 30`,
      ],
      { stdio: ["ignore", "pipe", "pipe"], detached: true },
    );
    children.push(rproc);
    let out = "";
    let err = "";
    rproc.stdout?.on("data", (d) => { out += d.toString("utf8"); });
    rproc.stderr?.on("data", (d) => { err += d.toString("utf8"); });
    rproc.on("error", reject);
    rproc.stdout?.on("end", () => {
      const line = out.split("\n").find((l) => l.startsWith("{"));
      if (line) {
        const j = JSON.parse(line);
        if (j.ready) {
          resolve(j);
          return;
        }
      }
      reject(new Error(`real stillfail-runner failed to start: ${err || out}`));
    });
  });
  extraPids.push(runnerReady.runner, runnerReady.pid, runnerReady.pgid);

  // (e) Spawn REAL release `stillfail-runner` for `sess-r8-big` writing 2.25 MiB (2,359,296 bytes, 36 x 64 KiB).
  const expectedBigChunks: Buffer[] = [];
  for (let i = 0; i < 36; i++) {
    const b = Buffer.alloc(65536, 65 + (i % 26));
    b.write(String(i).padStart(4, "0"), 0, "ascii");
    expectedBigChunks.push(b);
  }
  const expectedBigStr = Buffer.concat(expectedBigChunks).toString("utf8");
  assert.equal(Buffer.byteLength(expectedBigStr, "utf8"), 2_359_296);
  const bigRunnerReady = await new Promise<{ runner: number; pid: number; pgid: number; socket: string }>((resolve, reject) => {
    const rproc = spawn(
      runnerBin,
      [
        "--dir", runnersDir,
        "--id", "claude-sess-r8-big",
        "--cwd", data,
        "--",
        process.execPath, "-e",
        `for(let i=0;i<36;i++){const b=Buffer.alloc(65536,65+(i%26));b.write(String(i).padStart(4,"0"),0,"ascii");process.stdout.write(b);}setTimeout(()=>{},30000);`,
      ],
      { stdio: ["ignore", "pipe", "pipe"], detached: true },
    );
    children.push(rproc);
    let out = "";
    let err = "";
    rproc.stdout?.on("data", (d) => { out += d.toString("utf8"); });
    rproc.stderr?.on("data", (d) => { err += d.toString("utf8"); });
    rproc.on("error", reject);
    rproc.stdout?.on("end", () => {
      const line = out.split("\n").find((l) => l.startsWith("{"));
      if (line) {
        const j = JSON.parse(line);
        if (j.ready) {
          resolve(j);
          return;
        }
      }
      reject(new Error(`real big stillfail-runner failed to start: ${err || out}`));
    });
  });
  extraPids.push(bigRunnerReady.runner, bigRunnerReady.pid, bigRunnerReady.pgid);

  // Predecessor attaches, reads the initial 23 bytes, ACKs out=23, keep=0, and leaves cleanly.
  await new Promise<void>((resolve, reject) => {
    const s = createConnection(runnerReady.socket);
    let buf = "";
    let got = 0;
    const timer = setTimeout(() => { s.destroy(); reject(new Error(`predecessor timeout: got ${got}/23 bytes`)); }, 8_000);
    s.on("error", (e) => { clearTimeout(timer); reject(e); });
    s.on("connect", () => { s.write('{"op":"attach"}\n'); });
    s.on("data", (d) => {
      buf += d.toString("utf8");
      let nl = buf.indexOf("\n");
      while (nl >= 0) {
        const line = buf.slice(0, nl).trim();
        buf = buf.slice(nl + 1);
        if (line) {
          const msg = JSON.parse(line);
          if (msg.op === "out" && msg.stream === "out") {
            const chunk = Buffer.from(msg.data, "base64");
            got = Math.max(got, msg.at + chunk.length);
            if (got >= 23) {
              s.write('{"op":"ack","out":23,"err":0,"keep":0}\n{"op":"leave"}\n');
            }
          }
        }
        nl = buf.indexOf("\n");
      }
    });
    s.on("close", () => {
      clearTimeout(timer);
      if (got >= 23) resolve();
      else reject(new Error(`predecessor closed early with ${got}/23 bytes`));
    });
  });

  // (b) Seed Runner A for `sess-r7-restart` (16 bytes `[0..16)` + clean exit).
  const procA = spawn("sleep", ["30"], { stdio: "ignore" });
  children.push(procA);
  assert.ok(procA.pid && procA.pid > 1);
  const restartSockPath = join(runnersDir, "claude-sess-r7-restart.sock");
  let ackOutA = 0;
  const srvA = createNetServer((sock) => {
    let buf = "";
    sock.on("data", (d) => {
      buf += d.toString("utf8");
      let nl = buf.indexOf("\n");
      while (nl >= 0) {
        const line = buf.slice(0, nl).trim();
        buf = buf.slice(nl + 1);
        if (line) {
          const msg = JSON.parse(line);
          if (msg.op === "attach") {
            const payload = Buffer.from("runner-A-16byte!", "utf8");
            assert.equal(payload.length, 16);
            sock.write(
              JSON.stringify({ op: "attached", out: 0, err: 0, keep: 0 }) + "\n" +
              JSON.stringify({ op: "out", stream: "out", at: 0, data: payload.toString("base64") }) + "\n",
            );
          } else if (msg.op === "ack" && typeof msg.out === "number") {
            ackOutA = msg.out;
            if (ackOutA >= 16) {
              sock.write(JSON.stringify({ op: "exit", code: 0 }) + "\n");
            }
          }
        }
        nl = buf.indexOf("\n");
      }
    });
  });
  servers.push(srvA);
  await new Promise<void>((r) => srvA.listen(restartSockPath, () => r()));
  const startedAtA = Date.now();
  writeFileSync(
    join(runnersDir, "claude-sess-r7-restart.json"),
    JSON.stringify({
      id: "claude-sess-r7-restart",
      runner: procA.pid,
      pid: procA.pid,
      pgid: procA.pid,
      startedAt: startedAtA,
      socket: restartSockPath,
    }) + "\n",
  );

  // (d) Seed interleaved stdout/stderr split multi-byte UTF-8 + strict commit-order mock runner for `sess-r7-utf8`:
  // `stdout([0xE4, 0xB8])` -> `stderr("note")` -> `stdout([0xAD])` -> `stdout("1:start")` -> `stderr("2:warning")` -> `stdout("3:done")`
  // MUST emit exact order `["note", "中", "1:start", "2:warning", "3:done"]` (ZERO U+FFFD).
  const procUtf8 = spawn("sleep", ["30"], { stdio: "ignore" });
  children.push(procUtf8);
  assert.ok(procUtf8.pid && procUtf8.pid > 1);
  const utf8SockPath = join(runnersDir, "claude-sess-r7-utf8.sock");
  let ackOutUtf8 = 0;
  let ackErrUtf8 = 0;
  const srvUtf8 = createNetServer((sock) => {
    let buf = "";
    sock.on("data", (d) => {
      buf += d.toString("utf8");
      let nl = buf.indexOf("\n");
      while (nl >= 0) {
        const line = buf.slice(0, nl).trim();
        buf = buf.slice(nl + 1);
        if (line) {
          const msg = JSON.parse(line);
          if (msg.op === "attach") {
            sock.write(
              JSON.stringify({ op: "attached", out: 0, err: 0, keep: 0 }) + "\n" +
              JSON.stringify({ op: "out", stream: "out", at: 0, data: Buffer.from([0xe4, 0xb8]).toString("base64") }) + "\n" +
              JSON.stringify({ op: "out", stream: "err", at: 0, data: Buffer.from("note", "utf8").toString("base64") }) + "\n" +
              JSON.stringify({ op: "out", stream: "out", at: 2, data: Buffer.from([0xad]).toString("base64") }) + "\n" +
              JSON.stringify({ op: "out", stream: "out", at: 3, data: Buffer.from("1:start", "utf8").toString("base64") }) + "\n" +
              JSON.stringify({ op: "out", stream: "err", at: 4, data: Buffer.from("2:warning", "utf8").toString("base64") }) + "\n" +
              JSON.stringify({ op: "out", stream: "out", at: 10, data: Buffer.from("3:done", "utf8").toString("base64") }) + "\n",
            );
          } else if (msg.op === "ack") {
            if (typeof msg.out === "number") ackOutUtf8 = msg.out;
            if (typeof msg.err === "number") ackErrUtf8 = msg.err;
          }
        }
        nl = buf.indexOf("\n");
      }
    });
  });
  servers.push(srvUtf8);
  await new Promise<void>((r) => srvUtf8.listen(utf8SockPath, () => r()));
  writeFileSync(
    join(runnersDir, "claude-sess-r7-utf8.json"),
    JSON.stringify({
      id: "claude-sess-r7-utf8",
      runner: procUtf8.pid,
      pid: procUtf8.pid,
      pgid: procUtf8.pid,
      startedAt: Date.now(),
      socket: utf8SockPath,
    }) + "\n",
  );

  // (f) Seed 4,097 consecutive small frames for `sess-r9-small`:
  // frame 1 = `[0xE4, 0xB8]`, frame 2 = `[0xAD]` -> `"中"`, frames 3..4097 = 4,095 x `"a"` (4,098 bytes total).
  const procSmall = spawn("sleep", ["30"], { stdio: "ignore" });
  children.push(procSmall);
  assert.ok(procSmall.pid && procSmall.pid > 1);
  const smallSockPath = join(runnersDir, "claude-sess-r9-small.sock");
  let ackOutSmall = 0;
  const srvSmall = createNetServer((sock) => {
    let buf = "";
    sock.on("data", (d) => {
      buf += d.toString("utf8");
      let nl = buf.indexOf("\n");
      while (nl >= 0) {
        const line = buf.slice(0, nl).trim();
        buf = buf.slice(nl + 1);
        if (line) {
          const msg = JSON.parse(line);
          if (msg.op === "attach") {
            const lines: string[] = [
              JSON.stringify({ op: "attached", out: 0, err: 0, keep: 0 }),
              JSON.stringify({ op: "out", stream: "out", at: 0, data: Buffer.from([0xe4, 0xb8]).toString("base64") }),
              JSON.stringify({ op: "out", stream: "out", at: 2, data: Buffer.from([0xad]).toString("base64") }),
            ];
            const aB64 = Buffer.from("a", "utf8").toString("base64");
            for (let i = 0; i < 4095; i++) {
              lines.push(JSON.stringify({ op: "out", stream: "out", at: 3 + i, data: aB64 }));
            }
            sock.write(lines.join("\n") + "\n");
          } else if (msg.op === "ack" && typeof msg.out === "number") {
            ackOutSmall = msg.out;
          }
        }
        nl = buf.indexOf("\n");
      }
    });
  });
  servers.push(srvSmall);
  await new Promise<void>((r) => srvSmall.listen(smallSockPath, () => r()));
  writeFileSync(
    join(runnersDir, "claude-sess-r9-small.json"),
    JSON.stringify({
      id: "claude-sess-r9-small",
      runner: procSmall.pid,
      pid: procSmall.pid,
      pgid: procSmall.pid,
      startedAt: Date.now(),
      socket: smallSockPath,
    }) + "\n",
  );

  // 1st SIGUSR2 handover: pid1 -> pid2
  process.kill(lc.pid!, "SIGUSR2");
  const pid2 = await until("r7 pid2 after 1st SIGUSR2", () => {
    const p = readHubPid();
    return p && p !== pid1 ? p : null;
  }, 20_000);
  await until("r7 pid1 exited", () => !isAlive(pid1), 15_000);
  await until(`launcher confirms Node ${pid2} has taken over`, () => logs.includes(`Node ${pid2} has taken over`), 15_000);

  // Now emit the 15 post-handover bytes from the real `stillfail-runner` (offsets [23..38)).
  writeFileSync(triggerFile, "go\n");

  await until(
    "runner A, utf8 runner, and 4097-frame small runner acked",
    () => ackOutA >= 16 && ackOutUtf8 >= 16 && ackErrUtf8 >= 13 && ackOutSmall >= 4098,
    20_000,
  );
  procA.kill("SIGKILL");
  procUtf8.kill("SIGKILL");
  procSmall.kill("SIGKILL");
  srvA.close();
  srvUtf8.close();
  srvSmall.close();
  try { rmSync(restartSockPath, { force: true }); } catch {}
  try { rmSync(utf8SockPath, { force: true }); } catch {}
  try { rmSync(smallSockPath, { force: true }); } catch {}

  const { conn: adminConn2, helloReply: hello2 } = await openAdminConn(memberEp, stationId, frontAddr, memberJwt);
  assert.equal(hello2?.ok, true, JSON.stringify(hello2));
  // Verify (a): Pion adopted pre-ACKed real runner at out=23 and persisted the 15 new bytes!
  await until("GET /sessions/sess-r7-real adoptedOutput contains post-pion-15-b", async () => {
    const r = await adminCall(adminConn2, "GET", "/sessions/sess-r7-real");
    if (r.status !== 200) return false;
    const j = JSON.parse(r.body.toString("utf8"));
    return Array.isArray(j.adoptedOutput) && j.adoptedOutput.join("") === postText;
  }, 10_000);

  // Verify (d): interleaved split UTF-8 + strict commit order 1, 2, 3 with ZERO U+FFFD!
  const utf8Sess = await adminCall(adminConn2, "GET", "/sessions/sess-r7-utf8");
  assert.equal(utf8Sess.status, 200, utf8Sess.body.toString("utf8"));
  const utf8Json = JSON.parse(utf8Sess.body.toString("utf8"));
  assert.deepEqual(
    utf8Json.adoptedOutput,
    ["note", "中", "1:start", "2:warning", "3:done"],
    `expected strict commit order + split UTF-8 without U+FFFD, got: ${JSON.stringify(utf8Json)}`,
  );
  assert.equal(utf8Json.adoptedOutput.join("").includes("\uFFFD"), false);

  // Verify (f): 4,097 consecutive small frames (first 2 form `"中"`, rest 4,095 `"a"`) all read back via keyset pagination!
  const smallSess = await adminCall(adminConn2, "GET", "/sessions/sess-r9-small");
  assert.equal(smallSess.status, 200, smallSess.body.toString("utf8"));
  const smallJson = JSON.parse(smallSess.body.toString("utf8"));
  const smallJoined = (smallJson.adoptedOutput as string[]).join("");
  assert.equal(smallJoined.includes("\uFFFD"), false, "4097 small frames must NOT split leading UTF-8 into U+FFFD");
  assert.equal(
    smallJoined,
    "中" + "a".repeat(4095),
    `expected all 4097 small frames (4096 chars / 4098 bytes), got len=${smallJoined.length}, head=${JSON.stringify(smallJoined.slice(0, 8))}`,
  );

  // Verify (e): 2.25 MiB (2,359,296 bytes, 36 chunks) over REAL Launcher + MB Front -> HTTP 200, 0 reset, byte-exact!
  await until("GET /sessions/sess-r8-big returns full 2,359,296 bytes with HTTP 200", async () => {
    const r = await adminCall(adminConn2, "GET", "/sessions/sess-r8-big");
    if (r.status !== 200) return false;
    const j = JSON.parse(r.body.toString("utf8"));
    if (!Array.isArray(j.adoptedOutput)) return false;
    const joined = (j.adoptedOutput as string[]).join("");
    if (joined.length < 2_359_296) return false;
    assert.equal(joined.length, 2_359_296, `expected exact 2,359,296 bytes, got ${joined.length}`);
    assert.equal(joined, expectedBigStr, "2.25 MiB adoptedOutput must match byte-for-byte");
    return true;
  }, 20_000);
  await adminConn2.close(0, "done");

  // Simulate Pion -> Node rollback step on `sess-r7-real`: intermediate Node steals the runner socket,
  // verifies Pion #2 ACKed out=38, reads 14 new bytes (`mid-node-14-b\n`) and ACKs out=52, keep=0!
  await new Promise<void>((resolve, reject) => {
    const s = createConnection(runnerReady.socket);
    let buf = "";
    let got = 0;
    const timer = setTimeout(() => { s.destroy(); reject(new Error(`mid-node timeout: got ${got}/14 bytes`)); }, 10_000);
    s.on("error", (e) => { clearTimeout(timer); reject(e); });
    s.on("connect", () => { s.write('{"op":"attach"}\n'); });
    s.on("data", (d) => {
      buf += d.toString("utf8");
      let nl = buf.indexOf("\n");
      while (nl >= 0) {
        const line = buf.slice(0, nl).trim();
        buf = buf.slice(nl + 1);
        if (line) {
          const msg = JSON.parse(line);
          if (msg.op === "attached") {
            assert.equal(msg.out, 38, `expected Pion #2 ack.out === 38 before Node takeover, got ${JSON.stringify(msg)}`);
            assert.equal(msg.keep, 0, `expected keep === 0, got ${JSON.stringify(msg)}`);
            writeFileSync(triggerNodeFile, "go\n");
          } else if (msg.op === "out" && msg.stream === "out") {
            const raw = Buffer.from(msg.data, "base64");
            got += raw.length;
            if (got >= 14) {
              s.write(JSON.stringify({ op: "ack", out: 52, err: 0, keep: 0 }) + "\n");
              s.end();
            }
          }
        }
        nl = buf.indexOf("\n");
      }
    });
    s.on("close", () => {
      clearTimeout(timer);
      if (got >= 14) resolve();
      else reject(new Error(`mid-node closed early with ${got}/14 bytes`));
    });
  });

  // Verify independent `<data>/run/adopted-runners.db` (mode 0600) AND zero schema changes in `stillfail.db`!
  const adoptedDbPath = join(data, "run", "adopted-runners.db");
  assert.equal(existsSync(adoptedDbPath), true, `expected ${adoptedDbPath} on disk`);
  assert.equal(statSync(adoptedDbPath).mode & 0o777, 0o600, "adopted-runners.db must be 0600");
  const mainDb = new DatabaseSync(join(data, "stillfail.db"), { readOnly: true });
  const mainTables = (mainDb.prepare("SELECT name FROM sqlite_master WHERE type='table'").all() as { name: string }[]).map((r) => r.name);
  mainDb.close();
  assert.equal(mainTables.includes("runner_instances"), false, "stillfail.db must NOT contain runner_instances");
  assert.equal(mainTables.includes("runner_output"), false, "stillfail.db must NOT contain runner_output");

  // (b) Restart a NEW runner B for the SAME session `sess-r7-restart` (same runner_id, new PID & startedAt)
  // sending a different 16-byte payload at `[0..16)`.
  const procB = spawn("sleep", ["30"], { stdio: "ignore" });
  children.push(procB);
  assert.ok(procB.pid && procB.pid > 1 && procB.pid !== procA.pid);
  let ackOutB = 0;
  const srvB = createNetServer((sock) => {
    let buf = "";
    sock.on("data", (d) => {
      buf += d.toString("utf8");
      let nl = buf.indexOf("\n");
      while (nl >= 0) {
        const line = buf.slice(0, nl).trim();
        buf = buf.slice(nl + 1);
        if (line) {
          const msg = JSON.parse(line);
          if (msg.op === "attach") {
            const payload = Buffer.from("runner-B-16byte!", "utf8");
            assert.equal(payload.length, 16);
            sock.write(
              JSON.stringify({ op: "attached", out: 0, err: 0, keep: 0 }) + "\n" +
              JSON.stringify({ op: "out", stream: "out", at: 0, data: payload.toString("base64") }) + "\n",
            );
          } else if (msg.op === "ack" && typeof msg.out === "number") {
            ackOutB = msg.out;
          }
        }
        nl = buf.indexOf("\n");
      }
    });
  });
  servers.push(srvB);
  await new Promise<void>((r) => srvB.listen(restartSockPath, () => r()));
  writeFileSync(
    join(runnersDir, "claude-sess-r7-restart.json"),
    JSON.stringify({
      id: "claude-sess-r7-restart",
      runner: procB.pid,
      pid: procB.pid,
      pgid: procB.pid,
      startedAt: startedAtA + 5000,
      socket: restartSockPath,
    }) + "\n",
  );

  // Simulate R7 -> R9 DB upgrade: delete `runner_session_totals` row for `sess-r7-real` before 2nd handover
  // so Pion #3 must backfill from existing `runner_output` (15B) + new `after-pion3-x\n` (14B) = 29B!
  const upgradeDb = new DatabaseSync(adoptedDbPath);
  upgradeDb.prepare("DELETE FROM runner_session_totals WHERE session_key = ?").run("sess-r7-real");
  upgradeDb.close();

  // 2nd normal SIGUSR2 handover: pid2 -> pid3
  process.kill(lc.pid!, "SIGUSR2");
  const pid3 = await until("r7 pid3 after 2nd SIGUSR2", () => {
    const p = readHubPid();
    return p && p !== pid2 ? p : null;
  }, 20_000);
  await until("r7 pid2 exited", () => !isAlive(pid2), 15_000);

  await until("restarted runner B acked to 16", () => ackOutB >= 16, 10_000);
  procB.kill("SIGKILL");

  // Trigger final 14 bytes (`after-pion3-x\n`) on `sess-r7-real` after Pion #3 raised baseline from 38 -> 52!
  writeFileSync(triggerPion3File, "go\n");

  const { conn: adminConn3, helloReply: hello3 } = await openAdminConn(memberEp, stationId, frontAddr, memberJwt);
  assert.equal(hello3?.ok, true, JSON.stringify(hello3));
  // Verify (a) Pion -> Node -> Pion cutback: Pion #3 raised baseline to 52, persisted `after-pion3-x\n`,
  // and restored `post-pion-15-b\n` + `after-pion3-x\n` from adopted-runners.db!
  await until("GET /sessions/sess-r7-real contains post-pion-15-b and after-pion3-x", async () => {
    const r = await adminCall(adminConn3, "GET", "/sessions/sess-r7-real");
    if (r.status !== 200) return false;
    const j = JSON.parse(r.body.toString("utf8"));
    return Array.isArray(j.adoptedOutput) && j.adoptedOutput.join("") === postText + afterPion3Text;
  }, 10_000);
  // Verify (b) BOTH runner A and restarted runner B outputs are preserved:
  const restartSess = await adminCall(adminConn3, "GET", "/sessions/sess-r7-restart");
  assert.equal(restartSess.status, 200, restartSess.body.toString("utf8"));
  const restartJson = JSON.parse(restartSess.body.toString("utf8"));
  const restartAll = (restartJson.adoptedOutput as string[]).join("");
  assert.ok(
    restartAll.includes("runner-A-16byte!") && restartAll.includes("runner-B-16byte!"),
    `restarted runner B must NOT be skipped; expected both A and B outputs, got: ${JSON.stringify(restartJson)}`,
  );
  await adminConn3.close(0, "done");

  // Verify directly with the REAL `stillfail-runner` that Pion #3 ACKed `out === 66` and `keep === 0`!
  const attachedAck = await new Promise<{ op: string; out: number; err: number; keep: number | null }>((resolve, reject) => {
    const s = createConnection(runnerReady.socket);
    let buf = "";
    const timer = setTimeout(() => { s.destroy(); reject(new Error("timeout waiting for real runner attached frame")); }, 5_000);
    s.on("error", (e) => { clearTimeout(timer); reject(e); });
    s.on("connect", () => { s.write('{"op":"attach"}\n'); });
    s.on("data", (d) => {
      buf += d.toString("utf8");
      const nl = buf.indexOf("\n");
      if (nl >= 0) {
        clearTimeout(timer);
        const msg = JSON.parse(buf.slice(0, nl));
        s.destroy();
        resolve(msg);
      }
    });
  });
  assert.equal(attachedAck.op, "attached", JSON.stringify(attachedAck));
  assert.equal(attachedAck.out, 66, `real runner must have received Pion #3 ack.out === 66, got ${JSON.stringify(attachedAck)}`);
  assert.equal(attachedAck.keep, 0, `real runner must have received ack.keep === 0, got ${JSON.stringify(attachedAck)}`);

  // Verify R7 -> R9 `runner_session_totals` upgrade backfill computed exact total (15B + 14B = 29B)!
  const checkBackfillDb = new DatabaseSync(adoptedDbPath, { readOnly: true });
  const totRow = checkBackfillDb
    .prepare("SELECT total_bytes FROM runner_session_totals WHERE session_key = ?")
    .get("sess-r7-real") as { total_bytes: number } | undefined;
  checkBackfillDb.close();
  assert.equal(
    totRow?.total_bytes,
    Buffer.byteLength(postText, "utf8") + Buffer.byteLength(afterPion3Text, "utf8"),
    `expected backfilled runner_session_totals.total_bytes === 29, got ${JSON.stringify(totRow)}`,
  );

  lc.kill("SIGTERM");
  assert.equal(await Promise.race([lcExit, new Promise<null>((r) => setTimeout(() => r(null), 15_000))]), 0, logs);
  await until("r7 pid3 exited cleanly", () => !isAlive(pid3), 10_000);

  // (c) DB write failure fail-stop: pre-occupy `<dataFail>/run/adopted-runners.db` as a directory,
  // send `[0..12)` and `[12..24)` -> assert socket closes fail-stop with `ack.out === 0` (`ackCount === 0`)!
  const dataFail = freshDir("r7-failstop-data");
  const driveFail = freshDir("r7-failstop-drive");
  const failFrontPort = await pickFreeUdpPort();
  seedWholeDataDir(dataFail, stSeed, stationId, memberEp.id(), driveFail, ws, grantKeys);
  const wdFail1 = startWholeDaemon(bin, dataFail);
  await until("failstop setup daemon ready", () => wdFail1.messages.find((m) => m.ready === true), 10_000);
  const failMeshAddr = await until("failstop setup mesh bound", () => wdFail1.meshAddr(), 10_000);
  const { conn: fAdmin, helloReply: fHello } = await openAdminConn(memberEp, stationId, failMeshAddr, memberJwt);
  assert.equal(fHello?.ok, true);
  const fCreate = await adminCall(
    fAdmin,
    "POST",
    "/sessions",
    { "content-type": "application/json" },
    Buffer.from(JSON.stringify({ key: "sess-r7-failstop", title: "R7 FailStop" })),
  );
  assert.equal(fCreate.status, 200);
  await fAdmin.close(0, "done");
  wdFail1.sendCtrl({ op: "stop" });
  assert.equal(await wdFail1.waitExit(), 0, wdFail1.stderr());

  // Block `<dataFail>/run/adopted-runners.db` as a directory and seed a claimed mock runner.
  mkdirSync(join(dataFail, "run", "adopted-runners.db"), { recursive: true });
  const failRunnersDir = join(dataFail, "run", "runners");
  mkdirSync(failRunnersDir, { recursive: true });
  const failProc = spawn("sleep", ["30"], { stdio: "ignore" });
  children.push(failProc);
  assert.ok(failProc.pid && failProc.pid > 1);
  const failSockPath = join(failRunnersDir, "claude-sess-r7-failstop.sock");
  let failAttached = false;
  let failClosed = false;
  let failAckOut = 0;
  let failAckCount = 0;
  const failSrv = createNetServer((sock) => {
    let buf = "";
    sock.on("data", (d) => {
      buf += d.toString("utf8");
      let nl = buf.indexOf("\n");
      while (nl >= 0) {
        const line = buf.slice(0, nl).trim();
        buf = buf.slice(nl + 1);
        if (line) {
          const msg = JSON.parse(line);
          if (msg.op === "attach") {
            failAttached = true;
            sock.write(
              JSON.stringify({ op: "attached", out: 0, err: 0, keep: 0 }) + "\n" +
              JSON.stringify({ op: "out", stream: "out", at: 0, data: Buffer.from("frame-one-12", "utf8").toString("base64") }) + "\n" +
              JSON.stringify({ op: "out", stream: "out", at: 12, data: Buffer.from("frame-two-12", "utf8").toString("base64") }) + "\n",
            );
          } else if (msg.op === "ack") {
            failAckCount++;
            if (typeof msg.out === "number") failAckOut = msg.out;
          }
        }
        nl = buf.indexOf("\n");
      }
    });
    sock.on("close", () => { failClosed = true; });
  });
  servers.push(failSrv);
  await new Promise<void>((r) => failSrv.listen(failSockPath, () => r()));
  writeFileSync(
    join(failRunnersDir, "claude-sess-r7-failstop.json"),
    JSON.stringify({
      id: "claude-sess-r7-failstop",
      runner: failProc.pid,
      pid: failProc.pid,
      pgid: failProc.pid,
      startedAt: Date.now(),
      socket: failSockPath,
    }) + "\n",
  );

  const wdFail2 = startWholeDaemon(bin, dataFail, { STILLFAIL_MESH_BIND_ADDR: `127.0.0.1:${failFrontPort}` });
  await until("failstop daemon ready", () => wdFail2.messages.find((m) => m.ready === true), 10_000);
  await until("failstop runner attached and closed on DB error", () => failAttached && failClosed, 10_000);
  assert.equal(failAckOut, 0, `DB write failure MUST keep ack.out at 0 (before gap), got ${failAckOut}`);
  assert.equal(failAckCount, 0, `DB write failure MUST send 0 ACKs, got ${failAckCount}`);
  failProc.kill("SIGKILL");
  wdFail2.sendCtrl({ op: "stop" });
  assert.equal(await wdFail2.waitExit(), 0, wdFail2.stderr());
});

test("W17C2.14: --smoke-vault-sqlite + live Admin/1 Vault HTTP routes, unified ConfigFile settings (mcpServers/updates), and workspaces", { skip: process.platform === "win32" }, async () => {
  const smokeRes = spawnSync(bin, ["--smoke-vault-sqlite"], { encoding: "utf8", timeout: 15_000 });
  assert.equal(smokeRes.status, 0, `--smoke-vault-sqlite failed: ${smokeRes.stderr}`);
  const smokeJson = JSON.parse(smokeRes.stdout.trim());
  assert.equal(smokeJson.ok, true);
  assert.equal(smokeJson.sqlite_vault, true);

  const addon = resolveMeshAddon();
  const { grantKeys, signMemberJwt } = makeGrantKeysAndSigner();
  const base = mkdtempSync(join(tmpdir(), "stillfail-w17c2-e2e-"));
  dirs.push(base);
  const data = join(base, "data");
  const drive = join(base, "drive");
  mkdirSync(drive, { recursive: true });

  const stSeed = randomBytes(32);
  const probe = await addon.bind({ secretKey: stSeed, alpns: [ADMIN_ALPN], relayUrls: [], discovery: false, dht: false, bindAddr: "127.0.0.1:0" });
  const stationId = probe.id();
  await probe.close();

  const epOwner = await addon.bind({ secretKey: randomBytes(32), alpns: [ADMIN_ALPN], relayUrls: [], discovery: false, dht: false, bindAddr: "127.0.0.1:0" });
  endpoints.push(epOwner);

  const ws = "ws-w17c2";
  seedWholeDataDir(data, stSeed, stationId, epOwner.id(), drive, ws, grantKeys, undefined);

  const wd = startWholeDaemon(bin, data);
  await until("w17c2 daemon ready", () => wd.messages.find((m) => m.ready === true));
  const meshAddr = await until("w17c2 mesh bound", () => wd.meshAddr());

  const jwtOwner = signMemberJwt({ ws, device: epOwner.id(), sub: "u-owner", email: "owner@example.com", name: "Owner", role: "owner" });
  const { conn, helloReply } = await openAdminConn(epOwner, stationId, meshAddr, jwtOwner);
  assert.equal(helloReply?.ok, true, JSON.stringify(helloReply));

  // 1. Vault HTTP routes wired live over personal vault lock outside security mode
  for (const path of ["/vault/vaults", "/vault/discover", "/vault/asks", "/vault/joins", "/vault/items", "/vault/boxes"]) {
    const r = await adminCall(conn, "GET", path);
    assert.equal(r.status, 200, `GET ${path} expected 200 over personal vault lock, got ${r.status}: ${r.body.toString()}`);
  }
  const unknownVaultItems = await adminCall(conn, "GET", "/vault/items?vault=nonexistent");
  assert.equal(unknownVaultItems.status, 404, `GET /vault/items?vault=nonexistent expected 404, got ${unknownVaultItems.status}: ${unknownVaultItems.body.toString()}`);

  // Unimplemented / unported partial ops return honest 501 (ZERO fake 200 stubs!)
  for (const [m, p, body] of [
    ["GET", "/vault/uses", undefined],
    ["GET", "/vault/plain", undefined],
    ["GET", "/stars", undefined],
    ["GET", "/resources", undefined],
    ["GET", "/memory", undefined],
    ["GET", "/mcp-servers", undefined],
    ["PUT", "/mcp-servers", JSON.stringify({ servers: {} })],
    ["POST", "/updates", "{}"],
    ["POST", "/updates/check", "{}"],
  ] as const) {
    const resp = await adminCall(conn, m, p, { "content-type": "application/json" }, body !== undefined ? Buffer.from(body) : undefined);
    assert.equal(resp.status, 501, `${m} ${p} expected honest 501, got ${resp.status}: ${resp.body.toString()}`);
  }

  // 2. Unified ConfigFile settings mutations with redaction (`agentEnv`, `updates.channel`, `drive.roots`)
  const putEnv = await adminCall(
    conn,
    "PUT",
    "/agent-env",
    { "content-type": "application/json" },
    Buffer.from(JSON.stringify({ text: "PLAIN_VAR=hello\nMY_API_TOKEN=tok_secret_888" })),
  );
  assert.equal(putEnv.status, 200, `PUT /agent-env failed: ${putEnv.body.toString()}`);
  assert.ok(!putEnv.body.toString().includes("tok_secret_888"), "PUT /agent-env must redact secret tokens");

  const putCh = await adminCall(
    conn,
    "POST",
    "/updates/channel",
    { "content-type": "application/json" },
    Buffer.from(JSON.stringify({ channel: "beta" })),
  );
  assert.equal(putCh.status, 200, `POST /updates/channel failed: ${putCh.body.toString()}`);
  const cfgDisk = JSON.parse(readFileSync(join(data, "config.json"), "utf8"));
  assert.equal(cfgDisk.updateChannel, "beta");
  assert.equal(cfgDisk.agentEnv?.MY_API_TOKEN, "tok_secret_888");

  // 3. `GET /status` WaitingTracker runs real SQLite turns join with zero SQL errors + `/workspaces`
  const statusResp = await adminCall(conn, "GET", "/status");
  assert.equal(statusResp.status, 200, `GET /status WaitingTracker failed: ${statusResp.body.toString()}`);

  const wsResp = await adminCall(conn, "GET", "/workspaces");
  assert.equal(wsResp.status, 200, `GET /workspaces failed: ${wsResp.body.toString()}`);
  assert.ok(wsResp.body.toString().includes(ws), `GET /workspaces missing ${ws}: ${wsResp.body.toString()}`);

  await conn.close(0, "done");
  wd.sendCtrl({ op: "stop" });
  assert.equal(await wd.waitExit(), 0, wd.stderr());
});
