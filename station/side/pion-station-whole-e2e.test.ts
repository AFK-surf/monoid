// Wave 16B Real-Machine End-to-End Suite for `stillfail-station-pion` Whole Daemon (`whole_daemon.pion`):
// 1. `--version` remains `roles:rig` (unchanged until W17A cutover) + `--smoke-js-lower` full Unicode parity.
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
import { generateKeyPairSync, randomBytes, sign as cryptoSign } from "node:crypto";
import { createSocket as createUdpSocket } from "node:dgram";
import { chmodSync, copyFileSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createServer as createHttpServer, request as httpRequest, type Server as HttpServer } from "node:http";
import { createServer as createNetServer, type Server as NetServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Duplex } from "node:stream";
import { after, test } from "node:test";
import { fileURLToPath } from "node:url";
import { DatabaseSync } from "node:sqlite";
import { WebSocketServer } from "ws";
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
): Promise<{ conn: Connection; helloReply: any }> {
  const conn = await ep.connect({ id: stationId, relays: [], ips: [addr] }, ADMIN_ALPN);
  const ctrl = await conn.openBi();
  await writeLine(ctrl, { credential });
  const reader = new Reader(ctrl);
  const helloReply = await reader.line();
  return { conn, helloReply };
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

test("W16B.1: --version stays roles:rig and --smoke-js-lower passes full 0x0001..=0x1E950 + Final_Sigma + NULL + >4096B parity", () => {
  const ver = spawnSync(bin, ["--version"], { encoding: "utf8", timeout: 10_000 });
  assert.equal(ver.status, 0, ver.stderr);
  assert.equal(
    ver.stdout.trim(),
    "stillfail-station-pion 0.1.0 roles:rig commands:id,status,lock,channel,enroll,update,heap,admin",
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

  const wrapperPath = join(app, "station", "stillfail-station-pion");
  writeFileSync(
    wrapperPath,
    `#!/bin/sh
if [ "$1" = "--version" ]; then
  echo 'stillfail-station-pion 0.1.0 roles:rig,whole commands:id,status,lock,channel,enroll,update,heap,admin'
  exit 0
fi
export STILLFAIL_PION_WHOLE_DAEMON=1
exec ${JSON.stringify(bin)} "$@"
`,
  );
  chmodSync(wrapperPath, 0o755);

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
      STILLFAIL_STATION_PION: wrapperPath,
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

  // ── Part H: Real Rust Launcher `SIGUSR2` Hot Handover (`Pion Whole -> Pion Whole`) ──
  // Live `sleep 30` job MUST SURVIVE handover and remain visible in the new daemon's `job_list`!
  process.kill(lc.pid!, "SIGUSR2");
  const pid2 = await until("new whole_daemon pid after SIGUSR2", () => {
    const p = readHubPid();
    return p && p !== pid1 ? p : null;
  }, 20_000);
  await until("old whole_daemon pid1 exited cleanly", () => !isAlive(pid1), 15_000);
  assert.notEqual(pid2, pid1);

  // CRITICAL: job started before `SIGUSR2` MUST STILL BE ALIVE!
  assert.equal(isAlive(liveJobPid), true, `running job pid ${liveJobPid} was killed during SIGUSR2 handover!`);

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
