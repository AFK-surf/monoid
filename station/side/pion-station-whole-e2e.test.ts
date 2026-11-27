// Wave 16B Real-Machine End-to-End Suite for `stillfail-station-pion` Whole Daemon (`whole_daemon.pion`):
// 1. `--version` remains `roles:rig` (unchanged until W17A cutover) + `--smoke-js-lower` full Unicode parity.
// 2. SQLite handover barrier + FIFO replay: predecessor holds `hub.json` -> `/mcp` returns 503 & DB not opened ->
//    predecessor exits -> atomic SQLite open, queued RPCs replay FIFO, `/mcp` becomes ready.
// 3. Inherited `mcpFd` + full MCP lifecycle via real Rust Launcher (`STILLFAIL_LAUNCHER`): `mcp.json` &
//    `serving("mcp", port)`, session creation with 32B CSPRNG Bearer token, `chat_create`/`chat_list`/`search`,
//    and immediate `401` revocation upon archive.
// 4. Peer-authenticated HTTP API + streaming Drive + Unicode search over real MB Front (`front.sock`):
//    unknown/unauthorized peer fail-closed rejected; authorized member calls `/status`, `/chats`,
//    `/threads/:id/messages`, `/search` (`Άννα İZMİR 300K` + `mix` NOT matching `mİx`), `/drive/upload` + `/drive/read`.
// 5. True full-duplex `PEER_HTTP_ALPN` half-open streaming test (zero EOF deadlock): client sends HTTP headers
//    without closing write-half (no FIN), immediately receives `200 OK` chunked SSE headers + live events while
//    write-half remains open.
// 6. Real Rust Launcher `SIGUSR2` `Pion Whole -> Pion Whole` zero-loss hot handover: sessions, messages, and
//    MCP Bearer tokens survive intact, old process exits cleanly with zero orphans.
import assert from "node:assert/strict";
import { type ChildProcess, execFileSync, spawn, spawnSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import { createSocket as createUdpSocket } from "node:dgram";
import { chmodSync, copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { request as httpRequest } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Duplex } from "node:stream";
import { after, test } from "node:test";
import { fileURLToPath } from "node:url";
import { DatabaseSync } from "node:sqlite";
import { loadMesh, type Endpoint } from "../src/mesh/native.ts";
import { PEER_BYTES_ALPN } from "../src/mesh/peer.ts";
import { PEER_HTTP_ALPN } from "../src/mesh/peer-http.ts";

const root = fileURLToPath(new URL("../..", import.meta.url));
const dirs: string[] = [];
const children: ChildProcess[] = [];
const endpoints: Endpoint[] = [];

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

after(async () => {
  for (const ep of endpoints.splice(0)) {
    try { await ep.close(); } catch {}
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

function seedWholeDataDir(
  data: string,
  stationSeed: Buffer,
  stationId: string,
  peerId: string,
  driveRoot: string,
  ws = "ws-whole-e2e",
) {
  mkdirSync(join(data, "mesh"), { recursive: true });
  mkdirSync(driveRoot, { recursive: true });
  writeFileSync(join(data, "mesh/secret.key"), stationSeed, { mode: 0o600 });
  const cloudObj = {
    origin: "",
    station: stationId,
    workspace: ws,
    workspace_name: "Whole E2E WS",
    name: "pion-whole-e2e",
    relay_url: "",
    relay_urls: [],
    grant_keys: {},
    peers: [{ id: peerId, name: "peer-member" }],
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

async function peerHttpCall(
  ep: Endpoint,
  stationId: string,
  addr: string,
  method: string,
  path: string,
  headers: Record<string, string>,
  body?: Buffer,
  timeoutMs = 10_000,
): Promise<{ status: number; headers: Record<string, string>; body: Buffer }> {
  const run = async () => {
    const conn = await ep.connect({ id: stationId, relays: [], ips: [addr] }, PEER_HTTP_ALPN);
    try {
      const stream = await conn.openBi();
      const hdrLines = [`${method} ${path} HTTP/1.1`, "Host: station"];
      for (const [k, v] of Object.entries(headers)) {
        hdrLines.push(`${k}: ${v}`);
      }
      if (body && body.length > 0) {
        hdrLines.push(`Content-Length: ${body.length}`);
      }
      hdrLines.push("", "");
      await stream.write(Buffer.from(hdrLines.join("\r\n"), "utf8"));
      if (body && body.length > 0) {
        await stream.write(body);
      }
      // Intentionally do NOT wait on finish before reading; finish after writing body.
      await stream.finish();
      const chunks: Buffer[] = [];
      for (;;) {
        const c = await stream.read();
        if (c === null) break;
        chunks.push(c);
      }
      const raw = Buffer.concat(chunks);
      const sepIdx = raw.indexOf("\r\n\r\n");
      assert.ok(sepIdx >= 0, `expected HTTP/1.1 response head, got: ${raw.toString("utf8").slice(0, 200)}`);
      const headText = raw.subarray(0, sepIdx).toString("utf8");
      const respBody = raw.subarray(sepIdx + 4);
      const lines = headText.split("\r\n");
      const m = /^HTTP\/1\.[01]\s+(\d+)/.exec(lines[0] ?? "");
      assert.ok(m, `invalid HTTP status line: ${lines[0]}`);
      const respHeaders: Record<string, string> = {};
      for (let i = 1; i < lines.length; i++) {
        const col = lines[i]!.indexOf(":");
        if (col > 0) {
          respHeaders[lines[i]!.slice(0, col).trim().toLowerCase()] = lines[i]!.slice(col + 1).trim();
        }
      }
      return { status: Number(m[1]), headers: respHeaders, body: respBody };
    } catch (err) {
      throw new Error(`peerHttpCall(${method} ${path}): ${(err as Error).message}`);
    } finally {
      await conn.close(0, "done");
    }
  };
  return Promise.race([
    run(),
    new Promise<never>((_, rej) =>
      setTimeout(() => rej(new Error(`peerHttpCall(${method} ${path}) timed out after ${timeoutMs}ms`)), timeoutMs),
    ),
  ]);
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

test("W16B.2: SQLite handover barrier keeps /mcp at 503 & DB unopened until predecessor exits, then replays queued RPCs FIFO", { skip: process.platform === "win32" }, async () => {
  const addon = resolveMeshAddon();
  const data = freshDir("barrier-data");
  const drive = freshDir("barrier-drive");
  const stSeed = randomBytes(32);
  const probe = await addon.bind({ secretKey: stSeed, alpns: [], relayUrls: [], discovery: false, dht: false, bindAddr: "127.0.0.1:0" });
  const stationId = probe.id();
  await probe.close();

  const peerEp = await addon.bind({
    secretKey: randomBytes(32),
    alpns: [PEER_BYTES_ALPN, PEER_HTTP_ALPN],
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
  // (a) `/mcp` MUST return 503 without leaking internal paths/details.
  const preMcp = await httpCall(mcpPort, "POST", "/mcp", { "content-type": "application/json" }, "{}");
  assert.equal(preMcp.status, 503, `expected 503 before handover, got ${preMcp.status}: ${preMcp.body}`);
  assert.equal(preMcp.body.includes(data), false, "503 must not leak internal data path");

  // (b) `stillfail.db` MUST NOT have been opened/created yet!
  assert.equal(existsSync(join(data, "stillfail.db")), false, "SQLite DB must not be opened before predecessor exits");

  // (c) Queue a peer RPC BEFORE predecessor exits -> must wait in FIFO queue and complete once predecessor exits!
  const queuedRpcPromise = peerRpc(peerEp, stationId, meshAddr, ws, { method: "describe" }, undefined, 10_000);
  await new Promise((r) => setTimeout(r, 150));
  assert.equal(existsSync(join(data, "stillfail.db")), false, "SQLite DB still unopened while RPC is queued");

  // End predecessor -> atomic takeover -> queued RPC replays FIFO & `/mcp` stops returning 503!
  prev.kill("SIGKILL");
  await new Promise<void>((r) => prev.once("exit", () => r()));

  const descRes = await queuedRpcPromise;
  assert.equal(descRes.result.mode, "full");
  assert.equal(descRes.result.primaryOpen, true);
  assert.equal(JSON.parse(readFileSync(join(data, "run/hub.json"), "utf8")).pid, wd.child.pid);
  assert.equal(existsSync(join(data, "stillfail.db")), true, "SQLite DB opened after predecessor exited");

  const postMcp = await httpCall(mcpPort, "POST", "/mcp", { "content-type": "application/json" }, "{}");
  assert.equal(postMcp.status, 401, `expected 401 (ready, no bearer) after handover, got ${postMcp.status}`);

  wd.sendCtrl({ op: "stop" });
  assert.equal(await wd.waitExit(), 0, wd.stderr());
});

test("W16B.3-6: REAL Rust Launcher + MB Front: inherited mcpFd, MCP lifecycle, Peer HTTP API + Unicode search + Drive streaming, Half-Open PEER_HTTP_ALPN SSE (no FIN), and SIGUSR2 Pion Whole -> Pion Whole handover", { skip: process.platform === "win32" }, async () => {
  const launcher = resolveLauncherBinary();
  const readerBin = resolveReaderBinary();
  const addon = resolveMeshAddon();

  const app = freshDir("whole-launcher-app");
  const data = freshDir("whole-launcher-data");
  const drive = freshDir("whole-launcher-drive");
  mkdirSync(join(app, "station"), { recursive: true });
  copyFileSync(readerBin, join(app, "station", "stillfail-reader"));
  chmodSync(join(app, "station", "stillfail-reader"), 0o755);
  writeFileSync(join(app, "station", "main.js"), "process.exit(99);\n");
  writeFileSync(join(app, "BUILD"), "9916\n");

  // Wrapper inside temp test `app/station` so the REAL Rust launcher launches the REAL compiled
  // `stillfail-station-pion` binary in `--whole-daemon` mode while the real binary's `--version`
  // remains `roles:rig` until W17A!
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

  const authPeer = await addon.bind({
    secretKey: randomBytes(32),
    alpns: [PEER_BYTES_ALPN, PEER_HTTP_ALPN],
    relayUrls: [],
    discovery: false,
    dht: false,
    bindAddr: "127.0.0.1:0",
  });
  endpoints.push(authPeer);

  const roguePeer = await addon.bind({
    secretKey: randomBytes(32),
    alpns: [PEER_BYTES_ALPN, PEER_HTTP_ALPN],
    relayUrls: [],
    discovery: false,
    dht: false,
    bindAddr: "127.0.0.1:0",
  });
  endpoints.push(roguePeer);

  const frontPort = await pickFreeUdpPort();
  const frontAddr = `127.0.0.1:${frontPort}`;
  const ws = "ws-whole-live";
  seedWholeDataDir(data, stSeed, stationId, authPeer.id(), drive, ws);

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
      const r = await peerRpc(authPeer, stationId, frontAddr, ws, { method: "describe" }, undefined, 3_000);
      return r.result?.mode === "full" && r.result?.primaryOpen === true ? r : null;
    } catch { return null; }
  }, 15_000);

  // ── Part A: Unknown / unauthorized peer fail-closed rejected on BOTH RPC and PEER_HTTP_ALPN ──
  await assert.rejects(
    () => peerRpc(roguePeer, stationId, frontAddr, ws, { method: "describe" }, undefined, 4_000),
    /not another station|outside|refused|closed|error/i,
    "rogue peer RPC must be fail-closed rejected",
  );
  await assert.rejects(
    () => peerHttpCall(roguePeer, stationId, frontAddr, "GET", "/status", { "x-stillfail-workspace": ws }, undefined, 4_000),
    /.+/,
    "rogue peer PEER_HTTP_ALPN must be fail-closed rejected",
  );

  // ── Part B: Authorized Peer HTTP API (`/status`, `POST /sessions`, `POST /threads/:id/messages`, `/chats`, `/search`) ──
  const authHeaders = { "x-stillfail-workspace": ws, "x-stillfail-email": "alice@example.com", "x-stillfail-role": "owner" };
  const statusResp = await peerHttpCall(authPeer, stationId, frontAddr, "GET", "/status", authHeaders);
  assert.equal(statusResp.status, 200, statusResp.body.toString("utf8"));
  const statusJson = JSON.parse(statusResp.body.toString("utf8"));
  assert.equal(statusJson.station, stationId);
  assert.equal(statusJson.workspace, ws);

  const sessCreate = await peerHttpCall(
    authPeer,
    stationId,
    frontAddr,
    "POST",
    "/sessions",
    { ...authHeaders, "content-type": "application/json" },
    Buffer.from(JSON.stringify({ key: "sess-unicode-1", title: "Greek & Turkish" })),
  );
  assert.equal(sessCreate.status, 200, sessCreate.body.toString("utf8"));
  const createdSess = JSON.parse(sessCreate.body.toString("utf8"));
  const threadId = Number(createdSess.thread);
  assert.ok(threadId > 0);

  // Post messages with Greek/Turkish/Kelvin and `mİx`
  const post1 = await peerHttpCall(
    authPeer,
    stationId,
    frontAddr,
    "POST",
    `/threads/${threadId}/messages`,
    { ...authHeaders, "content-type": "application/json" },
    Buffer.from(JSON.stringify({ text: "Άννα İZMİR 300K" })),
  );
  assert.equal(post1.status, 200, post1.body.toString("utf8"));

  const post2 = await peerHttpCall(
    authPeer,
    stationId,
    frontAddr,
    "POST",
    `/threads/${threadId}/messages`,
    { ...authHeaders, "content-type": "application/json" },
    Buffer.from(JSON.stringify({ text: "only mİx here" })),
  );
  assert.equal(post2.status, 200, post2.body.toString("utf8"));

  const chatsResp = await peerHttpCall(authPeer, stationId, frontAddr, "GET", "/chats", authHeaders);
  assert.equal(chatsResp.status, 200);
  const chatsJson = JSON.parse(chatsResp.body.toString("utf8"));
  assert.ok(chatsJson.total >= 1);

  // Unicode case-insensitive search: `άννα` & `300k` match `Άννα İZMİR 300K`; `mix` MUST NOT match `mİx`!
  const searchHit = await peerHttpCall(
    authPeer,
    stationId,
    frontAddr,
    "GET",
    `/search?q=${encodeURIComponent("άννα 300k")}`,
    authHeaders,
  );
  assert.equal(searchHit.status, 200, searchHit.body.toString("utf8"));
  const hitJson = JSON.parse(searchHit.body.toString("utf8"));
  const msgGroup = (hitJson.groups ?? []).find((g: any) => g.kind === "message");
  assert.ok(msgGroup && msgGroup.hits.length >= 1, `expected Unicode search hit, got: ${searchHit.body.toString("utf8")}`);

  const searchNoMix = await peerHttpCall(
    authPeer,
    stationId,
    frontAddr,
    "GET",
    "/search?q=mix",
    authHeaders,
  );
  assert.equal(searchNoMix.status, 200);
  const noMixJson = JSON.parse(searchNoMix.body.toString("utf8"));
  const noMixMsg = (noMixJson.groups ?? []).find((g: any) => g.kind === "message");
  assert.equal(noMixMsg?.hits?.length ?? 0, 0, `mix MUST NOT falsely match mİx: ${searchNoMix.body.toString("utf8")}`);

  // ── Part C: Streaming Drive `PUT /drive/upload` + `GET /drive/read` (150 KiB real disk) ──
  mkdirSync(join(drive, "nested"), { recursive: true });
  const payload = randomBytes(150 * 1024);
  const upResp = await peerHttpCall(
    authPeer,
    stationId,
    frontAddr,
    "PUT",
    `/drive/upload?root=${encodeURIComponent(drive)}&path=nested/blob.bin&id=up-1&offset=0&total=${payload.length}&replace=1`,
    { ...authHeaders, "content-type": "application/octet-stream" },
    payload,
  );
  assert.equal(upResp.status, 200, upResp.body.toString("utf8"));
  const upJson = JSON.parse(upResp.body.toString("utf8"));
  assert.equal(upJson.have, payload.length);
  assert.equal(existsSync(join(drive, "nested/blob.bin")), true);

  const dlResp = await peerHttpCall(
    authPeer,
    stationId,
    frontAddr,
    "GET",
    `/drive/read?root=${encodeURIComponent(drive)}&path=nested/blob.bin&offset=0&length=${payload.length}`,
    authHeaders,
  );
  assert.equal(dlResp.status, 200);
  assert.equal(dlResp.headers["stillfail-total"], String(payload.length));
  assert.ok(Number(dlResp.headers["stillfail-mtime"]) > 0);
  assert.equal(Buffer.compare(dlResp.body, payload), 0, "streamed drive download must match uploaded bytes 1:1");

  // ── Part D: True Full-Duplex `PEER_HTTP_ALPN` Half-Open Stream (NO client FIN!) ──
  const sseConn = await authPeer.connect({ id: stationId, relays: [], ips: [frontAddr] }, PEER_HTTP_ALPN);
  try {
    const sseStream = await sseConn.openBi();
    const sseReq = [
      "GET /events HTTP/1.1",
      "Host: station",
      `X-Stillfail-Workspace: ${ws}`,
      "X-Stillfail-Email: alice@example.com",
      "X-Stillfail-Role: owner",
      "",
      "",
    ].join("\r\n");
    await sseStream.write(Buffer.from(sseReq, "utf8"));
    // CRITICAL: DO NOT call `sseStream.finish()`! Keep client write-half open!

    let sseText = "";
    const readUntilContains = async (needle: string, timeoutMs = 6_000) => {
      const deadline = Date.now() + timeoutMs;
      while (!sseText.includes(needle) && Date.now() < deadline) {
        const chunk = await Promise.race([
          sseStream.read(),
          new Promise<never>((_, rej) => setTimeout(() => rej(new Error(`timeout waiting for SSE '${needle}'; got:\n${sseText}`)), Math.max(100, deadline - Date.now()))),
        ]);
        assert.notEqual(chunk, null, `SSE stream ended unexpectedly before '${needle}'`);
        sseText += chunk!.toString("utf8");
      }
      assert.ok(sseText.includes(needle), `missing '${needle}' in SSE stream:\n${sseText}`);
    };

    // Must immediately receive 200 OK + text/event-stream + `event: open` WHILE client write-half is still open!
    await readUntilContains("HTTP/1.1 200 OK");
    await readUntilContains("text/event-stream");
    await readUntilContains("event: open");

    // Trigger a live `"thread"` event while the SSE stream is half-open -> must arrive live!
    let postLive: { status: number; headers: Record<string, string>; body: Buffer };
    try {
      postLive = await peerHttpCall(
        authPeer,
        stationId,
        frontAddr,
        "POST",
        `/threads/${threadId}/messages`,
        { ...authHeaders, "content-type": "application/json" },
        Buffer.from(JSON.stringify({ text: "live-sse-ping" })),
      );
    } catch (e) {
      throw new Error(`${(e as Error).message}\n--- launcher logs ---\n${logs}`);
    }
    assert.equal(postLive.status, 200);
    await readUntilContains("live-sse-ping");

    // Now cleanly close client write-half!
    await sseStream.finish();
  } finally {
    await sseConn.close(0, "done");
  }

  // ── Part E: Inherited `mcpFd` + MCP Full Lifecycle (32B CSPRNG token -> search/chat_create/chat_list -> archive -> 401) ──
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
  assert.ok(mcpSearch.body.includes("mcp-sentinel-phrase"), `search missing sentinel: ${mcpSearch.body}`);

  // ── Part F: REAL `SIGUSR2` `Pion Whole -> Pion Whole` Zero-Loss Hot Handover ──
  lc.kill("SIGUSR2");
  const pid2 = await until(
    "Pion Whole -> Pion Whole switched hub.json pid",
    () => {
      const p = readHubPid();
      return p && p !== pid1 ? p : null;
    },
    15_000,
  );
  await until("old whole_daemon process exited cleanly", () => !isAlive(pid1), 10_000);
  assert.notEqual(pid2, pid1);

  // After handover: inherited mcpPort & adminPort still work, sessions/messages/Bearer token survived losslessly!
  assert.equal((await httpCall(adminPort, "GET", "/healthz")).status, 200);
  const mcpAfterHo = await mcpCall(bearerToken, "search", { query: "mcp-sentinel-phrase" });
  assert.equal(mcpAfterHo.status, 200, `Bearer token must survive SIGUSR2 handover: ${mcpAfterHo.body}`);
  assert.ok(mcpAfterHo.body.includes("mcp-sentinel-phrase"));

  const chatsAfterHo = await peerHttpCall(authPeer, stationId, frontAddr, "GET", "/chats", authHeaders);
  assert.equal(chatsAfterHo.status, 200);
  assert.ok(JSON.parse(chatsAfterHo.body.toString("utf8")).total >= 2);

  // Archive session -> old Bearer token MUST immediately return 401!
  const archResp = await peerHttpCall(
    authPeer,
    stationId,
    frontAddr,
    "POST",
    "/sessions/sess-unicode-1/archive",
    { ...authHeaders, "content-type": "application/json" },
    Buffer.from("{}"),
  );
  assert.equal(archResp.status, 200, archResp.body.toString("utf8"));

  const revokedMcp = await mcpCall(bearerToken, "chat_list", {});
  assert.equal(revokedMcp.status, 401, `archived session token must immediately return 401, got ${revokedMcp.status}`);

  // Clean shutdown of launcher -> zero orphan whole_daemon!
  lc.kill("SIGTERM");
  const rc = await Promise.race([
    lcExit,
    new Promise<never>((_, rej) => setTimeout(() => rej(new Error(`launcher did not exit;\n${logs}`)), 10_000)),
  ]);
  assert.equal(rc, 0, logs);
  await until("second whole_daemon exited cleanly", () => !isAlive(pid2), 5_000);
});
