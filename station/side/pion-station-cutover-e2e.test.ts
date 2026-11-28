// Wave 17A-Whole-Cutover Release Gate Real-Machine E2E Suite (`stillfail-station-pion` `roles:rig,whole`):
// Zero temporary wrappers — real Rust Launcher + real MB Front + real `stillfail-station-pion` +
// real Node Station + real `stillfail-runner`!
//
// 1. Zero-Wrapper Full Station Launch & `is_rig` Auto-Routing (`whole_daemon` vs `rig_daemon`).
// 2. Real Node Station <-> Pion Whole Station Bidirectional Hot Handover (`SIGUSR2`):
//    Node -> Pion (DB intact + live `stillfail-runner` output seamless continuation) -> Node rollback (zero corruption).
// 3. Unified `EdgeMuxHub` & All 4 Wave 16C Edge OS Adapters Integration:
//    `ReplicaOsRuntime::before_store`, `DevicesOsRuntime` (`stillfail/http/1` `device:` 404/403/200 + backpressured TCP echo),
//    `BrowserOsManager`, `ConnectsOsRuntime`, `/status` `edge` view, clean shutdown (zero orphans / zero FD leaks).
// 4. Offline / Cloud-Unreachable Resilience:
//    unreachable cloud origin -> local MCP, Drive, `stillfail/http/1`, `stillfail/admin/1`, and `SIGUSR2` handover all work.
// 5. Astra R9 2 P2 Regressions (`adopted-runners.db`):
//    offset gap `[23,38) -> [52,66)` never stitches `"中"[0..2] + "文"[2..3]` into `"万"`,
//    active runner holds incomplete trailing UTF-8 without emitting `U+FFFD` until next byte/exit,
//    `PRAGMA user_version = 1` single-tx migration recomputes `runner_session_totals` & enforces 16 MiB trim.

import assert from "node:assert/strict";
import { type ChildProcess, execFileSync, spawn, spawnSync } from "node:child_process";
import { createHash, generateKeyPairSync, randomBytes, sign as cryptoSign } from "node:crypto";
import { createSocket as createUdpSocket } from "node:dgram";
import {
  chmodSync,
  copyFileSync,
  cpSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { createServer as createHttpServer, request as httpRequest, type Server as HttpServer } from "node:http";
import { createConnection, createServer as createNetServer, type AddressInfo, type Server as NetServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { after, test } from "node:test";
import { fileURLToPath, pathToFileURL } from "node:url";
import { WebSocketServer } from "ws";
import { DeviceRegistry } from "../src/devices/registry.ts";
import { loadMesh, type Connection, type Endpoint } from "../src/mesh/native.ts";
import { PEER_BYTES_ALPN } from "../src/mesh/peer.ts";
import { SCHEMA_VERSION } from "../src/store/schema.ts";
import { threadFile, writeCompressed } from "../src/store/archive.ts";
import { PEER_HTTP_ALPN } from "../src/mesh/peer-http.ts";
import { ALPN as ADMIN_ALPN } from "../src/mesh/serve.ts";
import { Reader, writeLine } from "../src/mesh/wire.ts";
import { takeBackSoon } from "../src/replica/restore.ts";
import { Store } from "../src/store/store.ts";
import { Exporter, genDir, nothingTold, ownDir } from "../test/reference/replica-export.ts";

const root = fileURLToPath(new URL("../..", import.meta.url));
const mainTs = fileURLToPath(new URL("../src/main.ts", import.meta.url));
const HEX32 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

const dirs: string[] = [];
const children: ChildProcess[] = [];
const endpoints: Endpoint[] = [];
const servers: (NetServer | HttpServer | WebSocketServer)[] = [];
const extraPids: number[] = [];

function freshDir(tag: string): string {
  // Keep path short so Unix socket paths stay well under 104 bytes.
  const dir = mkdtempSync(join(process.platform === "darwin" ? "/tmp" : tmpdir(), `w17a-${tag}-`));
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

function endAllInData(data: string): void {
  for (const f of ["run/station.json", "run/front.pid", "run/hub.json"]) {
    try {
      const text = readFileSync(join(data, f), "utf8");
      const pid = Number(f.endsWith(".pid") ? text.trim() : JSON.parse(text).pid);
      if (pid > 1 && pid !== process.pid) {
        try { process.kill(pid, "SIGKILL"); } catch {}
      }
    } catch {}
  }
  const runners = join(data, "run", "runners");
  if (existsSync(runners)) {
    for (const f of readdirSync(runners).filter((n) => n.endsWith(".json"))) {
      try {
        const info = JSON.parse(readFileSync(join(runners, f), "utf8"));
        if (info.pgid > 1) try { process.kill(-info.pgid, "SIGKILL"); } catch {}
        if (info.runner > 1) try { process.kill(info.runner, "SIGKILL"); } catch {}
      } catch {}
    }
  }
}

after(async () => {
  for (const s of servers.splice(0)) {
    try {
      if ("closeAllConnections" in s && typeof s.closeAllConnections === "function") s.closeAllConnections();
      s.close();
    } catch {}
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
      try { if (c.pid) process.kill(-c.pid, "SIGKILL"); } catch {}
      try { c.kill("SIGKILL"); } catch {}
    }
  }
  for (const d of dirs) endAllInData(d);
  for (const d of dirs.splice(0)) {
    rmSync(d, { recursive: true, force: true, maxRetries: 3, retryDelay: 50 });
  }
});

function resolveTarget(): string {
  return process.platform === "darwin" ? "darwin-arm64" : process.arch === "arm64" ? "linux-arm64" : "linux-x64";
}

function resolvePionBinary(): string {
  const envBin = process.env.STILLFAIL_STATION_PION;
  if (envBin && existsSync(envBin)) return envBin;
  const target = resolveTarget();
  const out = join(root, "pion/station-main/_build", `stillfail-station-pion-${target}`);
  if (!existsSync(out)) {
    execFileSync("bash", [join(root, "pion/station-main/scripts/build.sh"), target, out], {
      cwd: root,
      stdio: "inherit",
    });
  }
  return out;
}

function resolveNativeTool(envKey: string, pkg: string, binName: string): string {
  const envVal = process.env[envKey];
  if (envVal && existsSync(envVal)) return envVal;
  const dir = execFileSync(process.execPath, [join(root, "scripts/native.ts"), "path", pkg, resolveTarget()], {
    cwd: root,
    encoding: "utf8",
  }).trim();
  const candidate = join(dir, process.platform === "win32" ? `${binName}.exe` : binName);
  assert.ok(existsSync(candidate), `${pkg} binary not found at ${candidate}`);
  return candidate;
}

function resolveMeshAddon() {
  if (!process.env.STILLFAIL_MESH_NATIVE) {
    const dir = execFileSync(process.execPath, [join(root, "scripts/native.ts"), "path", "mesh", resolveTarget()], {
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
  ms = 20_000,
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
        sid: claims.sid ?? "sid-w17a",
      }),
    ).toString("base64url");
    const sig = cryptoSign(null, Buffer.from(`${head}.${body}`), privateKey).toString("base64url");
    return `${head}.${body}.${sig}`;
  };
  return { grantKeys, signMemberJwt };
}

async function bindClientEp(mesh: ReturnType<typeof loadMesh>): Promise<Endpoint> {
  const ep = await mesh.bind({
    secretKey: randomBytes(32),
    alpns: [],
    relayUrls: [],
    discovery: false,
    dht: false,
    bindAddr: "127.0.0.1:0",
  });
  endpoints.push(ep);
  return ep;
}

async function openAdminConn(
  clientEp: Endpoint,
  stationId: string,
  stationAddr: string,
  credential: string,
  coreVersion = 99999,
): Promise<{ conn: Connection; hello: Record<string, unknown> }> {
  const conn = await clientEp.connect({ id: stationId, relays: [], ips: [stationAddr] }, ADMIN_ALPN);
  const ctrl = await conn.openBi();
  await writeLine(ctrl, { credential, core: coreVersion });
  const reader = new Reader(ctrl, 65536);
  const hello = (await reader.line()) as Record<string, unknown>;
  assert.ok(hello && hello.ok === true, `admin hello failed: ${JSON.stringify(hello)}`);
  return { conn, hello };
}

async function adminRequest(
  conn: Connection,
  method: string,
  path: string,
  headers: [string, string][] = [],
  body?: Buffer | string,
): Promise<{ status: number; headers: [string, string][]; body: Buffer }> {
  const stream = await conn.openBi();
  const bodyBuf = body === undefined ? undefined : Buffer.isBuffer(body) ? body : Buffer.from(body);
  const hdrs: [string, string][] = [...headers];
  if (bodyBuf && !hdrs.some(([k]) => k.toLowerCase() === "content-length")) {
    hdrs.push(["content-length", String(bodyBuf.length)]);
  }
  await writeLine(stream, { method, path, headers: hdrs, body: bodyBuf !== undefined });
  if (bodyBuf) await stream.write(bodyBuf);
  await stream.finish();
  const reader = new Reader(stream, 65536);
  const head = (await reader.line()) as { status: number; headers?: [string, string][] };
  assert.ok(head && typeof head.status === "number", `bad admin head: ${JSON.stringify(head)}`);
  const chunks: Buffer[] = reader.carry.length > 0 ? [reader.carry] : [];
  for (;;) {
    const c = await stream.read();
    if (c === null) break;
    chunks.push(c);
  }
  return { status: head.status, headers: head.headers ?? [], body: Buffer.concat(chunks) };
}

function readHubPid(data: string): number {
  try {
    const j = JSON.parse(readFileSync(join(data, "run/hub.json"), "utf8"));
    return typeof j.pid === "number" ? j.pid : 0;
  } catch {
    return 0;
  }
}

function readPorts(data: string): { admin?: number; mcp?: number } {
  try {
    return JSON.parse(readFileSync(join(data, "run/ports.json"), "utf8"));
  } catch {
    return {};
  }
}

function readMcpPort(data: string): number {
  try {
    const j = JSON.parse(readFileSync(join(data, "run/mcp.json"), "utf8"));
    return typeof j.port === "number" ? j.port : 0;
  } catch {
    return 0;
  }
}

function installReleaseDir(
  appDir: string,
  pionBin: string,
  readerBin: string,
  runnerBin: string,
  withRealNodeMain: boolean,
): void {
  mkdirSync(join(appDir, "station"), { recursive: true });
  // ZERO WRAPPER: real `stillfail-station-pion` binary placed directly in `<app>/station/`!
  const installedPion = join(appDir, "station", "stillfail-station-pion");
  copyFileSync(pionBin, installedPion);
  chmodSync(installedPion, 0o755);

  const installedReader = join(appDir, "station", "stillfail-reader");
  copyFileSync(readerBin, installedReader);
  chmodSync(installedReader, 0o755);

  const installedRunner = join(appDir, "station", "stillfail-runner");
  copyFileSync(runnerBin, installedRunner);
  chmodSync(installedRunner, 0o755);

  // Also link node binary into `<app>/node/bin/node` so launcher uses our Node v24.
  mkdirSync(join(appDir, "node", "bin"), { recursive: true });
  const nodeLink = join(appDir, "node", "bin", "node");
  if (!existsSync(nodeLink)) symlinkSync(process.execPath, nodeLink);

  if (withRealNodeMain) {
    writeFileSync(
      join(appDir, "station", "main.js"),
      `import ${JSON.stringify(pathToFileURL(mainTs).href)};\n`,
    );
  } else {
    writeFileSync(join(appDir, "station", "main.js"), "process.exit(99);\n");
  }
  writeFileSync(join(appDir, "BUILD"), "9917\n");
}

function readProcComm(pid: number): string {
  try {
    return readFileSync(`/proc/${pid}/comm`, "utf8").trim();
  } catch {
    if (process.platform === "darwin") {
      const r = spawnSync("ps", ["-p", String(pid), "-o", "comm="], { encoding: "utf8" });
      if (r.status === 0) return r.stdout.trim();
    }
    return "";
  }
}

function readProcCmdline(pid: number): string {
  try {
    return readFileSync(`/proc/${pid}/cmdline`, "utf8").replace(/\0/g, " ").trim();
  } catch {
    if (process.platform === "darwin") {
      const r = spawnSync("ps", ["-p", String(pid), "-o", "args="], { encoding: "utf8" });
      if (r.status === 0) return r.stdout.trim();
    }
    return "";
  }
}

const pionBin = resolvePionBinary();
const launcherBin = resolveNativeTool("STILLFAIL_LAUNCHER", "launcher", "stillfail-station");
const readerBin = resolveNativeTool("STILLFAIL_MB_READER", "reader", "stillfail-reader");
const runnerBin = resolveNativeTool("STILLFAIL_RUNNER", "runner", "stillfail-runner");

test("W17A.1: Zero-wrapper real Launcher routes whole station -> whole_daemon and rig-only -> rig_daemon", async () => {
  // Verify `--version` directly advertises `roles:rig,whole` without any wrapper.
  const ver = spawnSync(pionBin, ["--version"], { encoding: "utf8", timeout: 10_000 });
  assert.equal(ver.status, 0, ver.stderr);
  assert.equal(
    ver.stdout.trim(),
    "stillfail-station-pion 0.1.0 roles:rig,whole commands:id,status,lock,channel,enroll,update,heap,admin,worktree",
  );

  const mesh = resolveMeshAddon();
  const { grantKeys, signMemberJwt } = makeGrantKeysAndSigner();

  // --- Part A: Whole station ---
  const wholeDir = freshDir("whole-auto");
  const wholeApp = join(wholeDir, "app");
  const wholeData = join(wholeDir, "data");
  installReleaseDir(wholeApp, pionBin, readerBin, runnerBin, false);
  mkdirSync(join(wholeData, "mesh"), { recursive: true });
  writeFileSync(join(wholeData, "config.json"), JSON.stringify({ engine: "pion" }));

  const idWhole = spawnSync(pionBin, ["id", "--data", wholeData], { encoding: "utf8" });
  assert.equal(idWhole.status, 0, idWhole.stderr);
  const wholeStationId = idWhole.stdout.trim();
  writeFileSync(
    join(wholeData, "mesh", "cloud.json"),
    JSON.stringify({
      workspace: "ws-whole-auto",
      workspace_name: "WholeAuto",
      station: wholeStationId,
      name: "pion-whole-auto",
      peers: [],
      relay_urls: [],
      grant_keys: grantKeys,
    }),
  );

  const wholeUdp = await pickFreeUdpPort();
  const wholeLogs: string[] = [];
  const wholeLauncher = spawn(launcherBin, ["run", "--app", wholeApp, "--data", wholeData, "--port", "0"], {
    env: {
      ...process.env,
      STILLFAIL_NO_DISCOVERY: "1",
      STILLFAIL_NO_DHT: "1",
      STILLFAIL_MESH_BIND_ADDR: `127.0.0.1:${wholeUdp}`,
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  children.push(wholeLauncher);
  wholeLauncher.stdout.on("data", (d) => wholeLogs.push(String(d)));
  wholeLauncher.stderr.on("data", (d) => wholeLogs.push(String(d)));

  const wholePid = await until("whole daemon hub.json", () => {
    const p = readHubPid(wholeData);
    return p > 0 && isAlive(p) ? p : null;
  });
  assert.match(readProcCmdline(wholePid), /stillfail-station-pion/, `expected real pion binary, got: ${readProcCmdline(wholePid)}`);
  const wholePort = await until("whole loopback port", () => readPorts(wholeData).admin || null);
  const hz = await httpCall(wholePort, "GET", "/healthz");
  assert.equal(hz.status, 200);

  // Connect over `stillfail/admin/1` and confirm `whole_daemon` + `edge` adapters active.
  const clientEp = await bindClientEp(mesh);
  const jwt = signMemberJwt({
    ws: "ws-whole-auto",
    device: clientEp.id(),
    sub: "u-admin",
    email: "admin@example.com",
    name: "Admin",
    role: "owner",
  });
  const { conn } = await until("whole admin connect", () =>
    openAdminConn(clientEp, wholeStationId, `127.0.0.1:${wholeUdp}`, jwt),
  );
  const stResp = await adminRequest(conn, "GET", "/status");
  assert.equal(stResp.status, 200, stResp.body.toString("utf8"));
  const stJson = JSON.parse(stResp.body.toString("utf8"));
  assert.equal(stJson.station, wholeStationId);
  assert.equal(stJson.edge?.replica?.ready, true);
  assert.equal(stJson.edge?.replica?.beforeStoreCalled, true);
  assert.equal(typeof stJson.edge?.devices?.registered, "number");
  assert.equal(typeof stJson.edge?.browser?.running, "number");
  assert.equal(stJson.edge?.connects?.stopped, false);
  conn.close(0, "done");

  wholeLauncher.kill("SIGTERM");
  await until("whole launcher exit", () => wholeLauncher.exitCode !== null || wholeLauncher.signalCode !== null);

  // --- Part B: Rig-only station auto-routing ---
  const rigDir = freshDir("rig-auto");
  const rigApp = join(rigDir, "app");
  const rigData = join(rigDir, "data");
  installReleaseDir(rigApp, pionBin, readerBin, runnerBin, false);
  mkdirSync(join(rigData, "mesh"), { recursive: true });
  writeFileSync(join(rigData, "config.json"), JSON.stringify({ engine: "pion" }));

  const idRig = spawnSync(pionBin, ["id", "--data", rigData], { encoding: "utf8" });
  assert.equal(idRig.status, 0, idRig.stderr);
  const rigStationId = idRig.stdout.trim();
  writeFileSync(
    join(rigData, "mesh", "cloud.json"),
    JSON.stringify({
      workspace: "ws-rig-auto",
      workspace_name: "RigAuto",
      station: rigStationId,
      name: "pion-rig-auto",
      rig: { owner: "u-owner", person: HEX32, owner_email: "o@example.com", owner_name: "Owner" },
      peers: [],
      relay_urls: [],
      grant_keys: grantKeys,
    }),
  );

  const rigUdp = await pickFreeUdpPort();
  const rigLogs: string[] = [];
  const rigLauncher = spawn(launcherBin, ["run", "--app", rigApp, "--data", rigData, "--port", "0"], {
    env: {
      ...process.env,
      STILLFAIL_NO_DISCOVERY: "1",
      STILLFAIL_NO_DHT: "1",
      STILLFAIL_MESH_BIND_ADDR: `127.0.0.1:${rigUdp}`,
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  children.push(rigLauncher);
  rigLauncher.stdout.on("data", (d) => rigLogs.push(String(d)));
  rigLauncher.stderr.on("data", (d) => rigLogs.push(String(d)));

  const rigPid = await until("rig daemon hub.json", () => {
    const p = readHubPid(rigData);
    return p > 0 && isAlive(p) ? p : null;
  });
  assert.match(readProcCmdline(rigPid), /stillfail-station-pion/);
  const rigPort = await until("rig loopback port", () => readPorts(rigData).admin || null);
  const rigHz = await httpCall(rigPort, "GET", "/healthz");
  assert.equal(rigHz.status, 200);
  await until("rig log prefix confirms rig_daemon role", () => rigLogs.join("").includes("[rig]"));

  rigLauncher.kill("SIGTERM");
  await until("rig launcher exit", () => rigLauncher.exitCode !== null || rigLauncher.signalCode !== null);
});

test("W17A.2: Real Node Station <-> Pion Whole Station bidirectional SIGUSR2 handover with live runner", async () => {
  const mesh = resolveMeshAddon();
  const { grantKeys, signMemberJwt } = makeGrantKeysAndSigner();

  const dir = freshDir("bidi-ho");
  const appDir = join(dir, "app");
  const dataDir = join(dir, "data");
  installReleaseDir(appDir, pionBin, readerBin, runnerBin, true);
  mkdirSync(join(dataDir, "mesh"), { recursive: true });
  mkdirSync(join(dataDir, "run", "runners"), { recursive: true });

  // Generate station key first via `pionBin id` so both Node & Pion share identical identity.
  const idRes = spawnSync(pionBin, ["id", "--data", dataDir], { encoding: "utf8" });
  assert.equal(idRes.status, 0, idRes.stderr);
  const stationId = idRes.stdout.trim();

  // Start with `"engine": "node"`!
  writeFileSync(join(dataDir, "config.json"), JSON.stringify({ engine: "node" }));
  writeFileSync(
    join(dataDir, "mesh", "cloud.json"),
    JSON.stringify({
      workspace: "ws-bidi",
      workspace_name: "BidiWS",
      station: stationId,
      name: "bidi-station",
      peers: [],
      relay_urls: [],
      grant_keys: grantKeys,
    }),
  );

  const udpPort = await pickFreeUdpPort();
  const logs: string[] = [];
  const launcher = spawn(launcherBin, ["run", "--app", appDir, "--data", dataDir, "--port", "0"], {
    env: {
      ...process.env,
      STILLFAIL_NO_DISCOVERY: "1",
      STILLFAIL_NO_DHT: "1",
      STILLFAIL_MESH_BIND_ADDR: `127.0.0.1:${udpPort}`,
      STILLFAIL_READER_ENGINE: "mb",
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  children.push(launcher);
  launcher.stdout.on("data", (d) => logs.push(String(d)));
  launcher.stderr.on("data", (d) => logs.push(String(d)));

  // Wait for Node station to be ready & open `stillfail.db`.
  const nodePid1 = await until(
    "Node station hub.json + stillfail.db",
    () => {
      const p = readHubPid(dataDir);
      if (p > 0 && isAlive(p) && existsSync(join(dataDir, "stillfail.db"))) {
        const port = readPorts(dataDir).admin ?? 0;
        if (port > 0) return p;
      }
      return null;
    },
    30_000,
  );
  assert.ok(
    readProcComm(nodePid1).includes("node") || readProcCmdline(nodePid1).includes("main.js"),
    `expected Node station first, got cmdline=${readProcCmdline(nodePid1)}`,
  );

  // Spawn a REAL `stillfail-runner` hosting a live process that emits pre-handover output,
  // waits on a gate file, then emits post-handover UTF-8 output and exits.
  const gateFile = join(dir, "release-runner.gate");
  const runnerId = "claude-sess-bidi-1";
  const runnerSock = join(dataDir, "run", "runners", `${runnerId}.sock`);
  const runnerScript = join(dir, "live-agent.sh");
  writeFileSync(
    runnerScript,
    `#!/bin/sh
printf 'pre-node-output\\n'
while [ ! -f ${JSON.stringify(gateFile)} ]; do sleep 0.05; done
printf '你好世界-after-node-to-pion\\n'
exit 0
`,
  );
  chmodSync(runnerScript, 0o755);

  const runnersDir = join(dataDir, "run", "runners");
  const runnerProc = spawn(
    runnerBin,
    ["--dir", runnersDir, "--id", runnerId, "--cwd", dir, "--", "/bin/sh", runnerScript],
    { stdio: "ignore", detached: true },
  );
  if (runnerProc.pid) extraPids.push(runnerProc.pid);
  await until("runner socket ready", () => existsSync(runnerSock) && existsSync(join(runnersDir, `${runnerId}.json`)));

  // Simulate predecessor Node pre-consuming & ACKing the pre-handover chunk (`pre-node-output\n`).
  let preAckedOut = 0;
  await new Promise<void>((resolve, reject) => {
    const sock = createConnection(runnerSock);
    let buf = "";
    const timer = setTimeout(() => {
      sock.destroy();
      reject(new Error("timeout pre-consuming runner output"));
    }, 10_000);
    sock.on("connect", () => {
      sock.write('{"op":"attach"}\n');
    });
    sock.on("data", (chunk) => {
      buf += chunk.toString("utf8");
      let nl = buf.indexOf("\n");
      while (nl >= 0) {
        const line = buf.slice(0, nl).trim();
        buf = buf.slice(nl + 1);
        if (line) {
          const msg = JSON.parse(line);
          if (msg.op === "out" && msg.stream === "out" && typeof msg.at === "number" && typeof msg.data === "string") {
            const rawLen = Buffer.from(msg.data, "base64").length;
            const endOff = msg.at + rawLen;
            if (endOff > preAckedOut) {
              preAckedOut = endOff;
              sock.write(JSON.stringify({ op: "ack", out: preAckedOut, err: 0, keep: 0 }) + "\n" + '{"op":"leave"}\n');
              clearTimeout(timer);
              sock.end();
              resolve();
              return;
            }
          }
        }
        nl = buf.indexOf("\n");
      }
    });
    sock.on("error", (e) => {
      clearTimeout(timer);
      reject(e);
    });
  });
  assert.ok(preAckedOut > 0, "expected pre-handover runner output to be ACKed");

  // Read runner metadata written by `stillfail-runner` (keeps exact `runner` PID & `startedAt`),
  // and write session row into Node's `stillfail.db` so Pion adopts it on takeover.
  const runnerMeta = JSON.parse(readFileSync(join(runnersDir, `${runnerId}.json`), "utf8"));
  if (typeof runnerMeta.runner === "number") extraPids.push(runnerMeta.runner);
  if (typeof runnerMeta.pgid === "number") extraPids.push(runnerMeta.pgid);
  const dbBefore = new DatabaseSync(join(dataDir, "stillfail.db"));
  const nowMs = Date.now();
  dbBefore.exec("PRAGMA busy_timeout=5000;");
  dbBefore
    .prepare(
      "INSERT OR REPLACE INTO sessions (key, connect, scope, title, runtime, profile, workspace, token, created_at, last_active_at, cwd, ws) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
    )
    .run("sess-bidi-1", "chat", "sess-bidi-1", "NodeToPionChat", "claude", "default", dir, randomBytes(32).toString("hex"), nowMs, nowMs, dir, "ws-bidi");
  dbBefore
    .prepare(
      "INSERT OR IGNORE INTO threads (id, surface, channel, thread_ts, title, created_at) VALUES (?, ?, ?, ?, ?, ?)",
    )
    .run(101, "web", "CHAT", "101.000", "NodeToPionChat", nowMs);
  dbBefore
    .prepare(
      "INSERT OR IGNORE INTO thread_sessions (thread, session, connect, joined_at) VALUES (?, ?, ?, ?)",
    )
    .run(101, "sess-bidi-1", "chat", nowMs);
  dbBefore.close();

  // --- Handover 1: Node -> Pion Whole (`SIGUSR2`) ---
  writeFileSync(join(dataDir, "config.json"), JSON.stringify({ engine: "pion", drive: { roots: [dir] } }));
  launcher.kill("SIGUSR2");

  const pionPid = await until(
    "Pion takeover after Node -> Pion SIGUSR2",
    () => {
      const p = readHubPid(dataDir);
      if (p > 0 && p !== nodePid1 && isAlive(p) && readProcCmdline(p).includes("stillfail-station-pion")) {
        return p;
      }
      return null;
    },
    30_000,
  );
  assert.notEqual(pionPid, nodePid1);
  assert.match(readProcCmdline(pionPid), /stillfail-station-pion/);

  // Release the live runner so Pion receives & commits post-handover UTF-8 output seamlessly!
  writeFileSync(gateFile, "go\n");

  const clientEp = await bindClientEp(mesh);
  const jwt = signMemberJwt({
    ws: "ws-bidi",
    device: clientEp.id(),
    sub: "u-bidi",
    email: "alice@example.com",
    name: "Alice",
    role: "owner",
  });
  const { conn: pionConn } = await until("admin connect to Pion after Node->Pion", () =>
    openAdminConn(clientEp, stationId, `127.0.0.1:${udpPort}`, jwt),
  );

  // Verify `stillfail.db` chat/session data survived Node -> Pion lossless.
  const chatsResp = await adminRequest(pionConn, "GET", "/chats");
  assert.equal(chatsResp.status, 200, chatsResp.body.toString("utf8"));
  assert.ok(chatsResp.body.toString("utf8").includes("NodeToPionChat"), "chat from Node missing after Pion takeover");

  // Verify live runner post-handover UTF-8 output arrived seamlessly without duplicating pre-ACKed chunk!
  const sessBody = await until("adoptedOutput from live runner in Pion", async () => {
    const r = await adminRequest(pionConn, "GET", "/sessions/sess-bidi-1");
    if (r.status !== 200) return null;
    const j = JSON.parse(r.body.toString("utf8"));
    const joined = Array.isArray(j.adoptedOutput) ? j.adoptedOutput.join("") : "";
    return joined.includes("你好世界-after-node-to-pion") ? joined : null;
  });
  assert.ok(sessBody.includes("你好世界-after-node-to-pion"));
  assert.ok(!sessBody.includes("pre-node-output"), "pre-ACKed Node output must not be replayed");
  pionConn.close(0, "done-pion");

  // --- Handover 2: Pion -> Node Rollback (`SIGUSR2`) ---
  writeFileSync(join(dataDir, "config.json"), JSON.stringify({ engine: "node" }));
  launcher.kill("SIGUSR2");

  const nodePid2 = await until(
    "Node rollback takeover after Pion -> Node SIGUSR2",
    () => {
      const p = readHubPid(dataDir);
      if (p > 0 && p !== pionPid && isAlive(p) && (readProcComm(p).includes("node") || readProcCmdline(p).includes("main.js"))) {
        return p;
      }
      return null;
    },
    30_000,
  );
  assert.notEqual(nodePid2, pionPid);

  const portAfter = await until("loopback port after rollback", () => readPorts(dataDir).admin || null);
  const hzAfter = await httpCall(portAfter, "GET", "/healthz");
  assert.equal(hzAfter.status, 200);

  // Verify SQLite integrity & zero data loss after full Node -> Pion -> Node roundtrip.
  const dbAfter = new DatabaseSync(join(dataDir, "stillfail.db"), { readOnly: true });
  const ic = dbAfter.prepare("PRAGMA integrity_check").get() as { integrity_check: string };
  assert.equal(ic.integrity_check, "ok");
  const sessRow = dbAfter.prepare("SELECT title FROM sessions WHERE key = 'sess-bidi-1'").get() as { title: string } | undefined;
  assert.equal(sessRow?.title, "NodeToPionChat");
  dbAfter.close();

  launcher.kill("SIGTERM");
  await until("bidi launcher exit", () => launcher.exitCode !== null || launcher.signalCode !== null);
});

test("W17A.3: SQLite devices + unified 404 + serial 501 + own-port loopback guard + live peer revocation", async () => {
  const mesh = resolveMeshAddon();
  const { grantKeys, signMemberJwt } = makeGrantKeysAndSigner();

  // Start a local TCP echo server that also tracks open upstream sockets for revocation proof.
  let openUpstreamSockets = 0;
  const echoSrv = createNetServer((sock) => {
    openUpstreamSockets++;
    sock.on("close", () => {
      openUpstreamSockets--;
    });
    sock.on("data", (chunk) => sock.write(chunk));
  });
  servers.push(echoSrv);
  await new Promise<void>((resolve) => echoSrv.listen(0, "127.0.0.1", () => resolve()));
  const echoPort = (echoSrv.address() as AddressInfo).port;

  const dir = freshDir("edge-dev");
  const appDir = join(dir, "app");
  const dataDir = join(dir, "data");
  installReleaseDir(appDir, pionBin, readerBin, runnerBin, false);
  mkdirSync(join(dataDir, "mesh"), { recursive: true });

  const idRes = spawnSync(pionBin, ["id", "--data", dataDir], { encoding: "utf8" });
  assert.equal(idRes.status, 0, idRes.stderr);
  const stationId = idRes.stdout.trim();

  // Create peer station identity so `stillfail/http/1` authorizes our test peer.
  const peerEp = await bindClientEp(mesh);
  const peerId = peerEp.id();

  // Controllable mock cloud presence server so we can push live peer revocation!
  let cloudConnected = false;
  const cloudSockets: import("ws").WebSocket[] = [];
  const cloudSrv = createHttpServer((_req, res) => {
    res.writeHead(200, { "content-type": "application/json" }).end("{}");
  });
  const cloudWss = new WebSocketServer({ noServer: true });
  servers.push(cloudWss, cloudSrv);
  cloudSrv.on("upgrade", (req, socket, head) => {
    cloudWss.handleUpgrade(req, socket, head, (ws) => {
      cloudSockets.push(ws);
      cloudConnected = true;
      ws.on("message", (m) => {
        if (String(m) === "ping") ws.send("pong");
      });
      ws.send(
        JSON.stringify({
          type: "state",
          workspace: "ws-edge",
          workspace_name: "EdgeWS",
          name: "edge-station",
          peers: [{ id: peerId, name: "peer-caller", ips: ["127.0.0.1"] }],
          relay_urls: [],
          grant_keys: grantKeys,
        }),
      );
    });
  });
  await new Promise<void>((resolve) => cloudSrv.listen(0, "127.0.0.1", () => resolve()));
  const cloudPort = (cloudSrv.address() as AddressInfo).port;

  writeFileSync(join(dataDir, "config.json"), JSON.stringify({ engine: "pion" }));
  writeFileSync(
    join(dataDir, "mesh", "cloud.json"),
    JSON.stringify({
      origin: `http://127.0.0.1:${cloudPort}`,
      workspace: "ws-edge",
      workspace_name: "EdgeWS",
      station: stationId,
      name: "edge-station",
      peers: [{ id: peerId, name: "peer-caller", ips: ["127.0.0.1"] }],
      relay_urls: [],
      grant_keys: grantKeys,
    }),
  );

  // Seed devices directly via real Node `Store.open` + `DeviceRegistry.add` into `stillfail.db`!
  const seedStore = Store.open(join(dataDir, "stillfail.db"), join(dataDir, "archive"));
  const seedReg = new DeviceRegistry(seedStore.db);
  const by = { sub: "u-edge", email: "edge@example.com", name: "Edge" };
  const seedAt = Date.now();
  const addedTcp = seedReg.add("ws-edge", by, { name: "echo-dev", kind: "tcp", target: `127.0.0.1:${echoPort}` }, seedAt);
  assert.ok(typeof addedTcp === "object", `seed tcp device failed: ${JSON.stringify(addedTcp)}`);
  const addedOtherWs = seedReg.add("ws-other", by, { name: "other-ws-dev", kind: "tcp", target: `127.0.0.1:${echoPort}` }, seedAt);
  assert.ok(typeof addedOtherWs === "object", `seed other-ws device failed: ${JSON.stringify(addedOtherWs)}`);
  const addedSerial = seedReg.add("ws-edge", by, { name: "serial-dev", kind: "serial", target: "/dev/ttyUSB0", baud: 115200 }, seedAt);
  assert.ok(typeof addedSerial === "object", `seed serial device failed: ${JSON.stringify(addedSerial)}`);
  seedStore.close();

  const udpPort = await pickFreeUdpPort();
  const launcher = spawn(launcherBin, ["run", "--app", appDir, "--data", dataDir, "--port", "0"], {
    env: {
      ...process.env,
      STILLFAIL_NO_DISCOVERY: "1",
      STILLFAIL_NO_DHT: "1",
      STILLFAIL_MESH_BIND_ADDR: `127.0.0.1:${udpPort}`,
    },
    stdio: "ignore",
  });
  children.push(launcher);

  const pionPid = await until("edge pion pid", () => {
    const p = readHubPid(dataDir);
    return p > 0 && isAlive(p) ? p : null;
  });
  const adminPort = await until("edge admin loopback port", () => readPorts(dataDir).admin || null);
  await until("edge cloud state connected", () => cloudConnected);

  // 1. Verify `/status` reports live SQLite `edge.devices.registered === 3` + unified `EdgeMuxHub` healthy.
  const jwt = signMemberJwt({
    ws: "ws-edge",
    device: peerId,
    sub: "u-edge",
    email: "edge@example.com",
    name: "Edge",
    role: "owner",
  });
  const { conn: adminConn } = await until("edge admin connect", () =>
    openAdminConn(peerEp, stationId, `127.0.0.1:${udpPort}`, jwt),
  );
  const stResp = await adminRequest(adminConn, "GET", "/status");
  assert.equal(stResp.status, 200);
  const stJson = JSON.parse(stResp.body.toString("utf8"));
  assert.equal(stJson.edge.replica.beforeStoreCalled, true);
  assert.equal(stJson.edge.devices.registered, 3);
  assert.equal(stJson.edge.browser.running, 0);
  assert.equal(stJson.edge.connects.stopped, false);
  assert.equal(stJson.edge.mux.deferredSysDropped, 0);
  adminConn.close(0, "done");

  // Dynamically add 2 own-port loopback alias devices (`127.0.0.2:<adminPort>` & `0.0.0.0:<adminPort>`)
  // into live SQLite `stillfail.db` without restarting Pion!
  const liveDb = new DatabaseSync(join(dataDir, "stillfail.db"));
  liveDb.exec("PRAGMA busy_timeout=5000;");
  const liveReg = new DeviceRegistry(liveDb);
  const liveAt = Date.now();
  const ownAlias1 = liveReg.add("ws-edge", by, { name: "own-127-2", kind: "tcp", target: `127.0.0.2:${adminPort}` }, liveAt);
  assert.ok(typeof ownAlias1 === "object");
  const ownAlias2 = liveReg.add("ws-edge", by, { name: "own-0000", kind: "tcp", target: `0.0.0.0:${adminPort}` }, liveAt);
  assert.ok(typeof ownAlias2 === "object");
  liveDb.close();

  // 2. Verify `stillfail/http/1` `device:` tunnel authorization, 501, own-port guard, & live revocation.
  const fdBefore = openFdCount(pionPid);
  const httpConn = await until("peer http conn ready", async () => {
    const c = await peerEp.connect({ id: stationId, relays: [], ips: [`127.0.0.1:${udpPort}`] }, PEER_HTTP_ALPN);
    try {
      const s = await c.openBi();
      await writeLine(s, { workspace: "ws-edge", device: addedTcp.id, session: "s1", tcp: true, probe: true });
      await s.finish();
      const r = new Reader(s, 65536);
      const h = (await r.line()) as { status: number };
      if (h.status === 200) return c;
    } catch {}
    c.close(0, "retry");
    return null;
  });

  // 2a. Unknown device -> 404.
  {
    const s = await httpConn.openBi();
    await writeLine(s, { workspace: "ws-edge", device: "deadbeef00000000", session: "s1", tcp: true, probe: true });
    await s.finish();
    const r = new Reader(s, 65536);
    const head = (await r.line()) as { status: number };
    assert.equal(head.status, 404, `expected 404 for unknown device, got ${JSON.stringify(head)}`);
  }

  // 2b. Cross-workspace device -> UNIFIED 404 (no existence oracle!).
  {
    const s = await httpConn.openBi();
    await writeLine(s, { workspace: "ws-edge", device: addedOtherWs.id, session: "s1", tcp: true, probe: true });
    await s.finish();
    const r = new Reader(s, 65536);
    const head = (await r.line()) as { status: number };
    assert.equal(head.status, 404, `expected unified 404 for cross-ws device, got ${JSON.stringify(head)}`);
  }

  // 2c. Unsupported serial device -> 501.
  {
    const s = await httpConn.openBi();
    await writeLine(s, { workspace: "ws-edge", device: addedSerial.id, session: "s1", tcp: true, probe: true });
    await s.finish();
    const r = new Reader(s, 65536);
    const head = (await r.line()) as { status: number };
    assert.equal(head.status, 501, `expected 501 for serial device, got ${JSON.stringify(head)}`);
  }

  // 2d. Own-port loopback alias (`127.0.0.2:<adminPort>` & `0.0.0.0:<adminPort>`) -> 403!
  for (const aliasId of [ownAlias1.id, ownAlias2.id]) {
    const s = await httpConn.openBi();
    await writeLine(s, { workspace: "ws-edge", device: aliasId, session: "s1", tcp: true, probe: true });
    await s.finish();
    const r = new Reader(s, 65536);
    const head = (await r.line()) as { status: number };
    assert.equal(head.status, 403, `expected 403 for own-port alias ${aliasId}, got ${JSON.stringify(head)}`);
  }

  // 2e. Authorized device full-duplex TCP tunnel (256 KiB payload) -> exact echo!
  {
    const s = await httpConn.openBi();
    await writeLine(s, { workspace: "ws-edge", device: addedTcp.id, session: "s1", tcp: true });
    const r = new Reader(s, 65536);
    const head = (await r.line()) as { status: number };
    assert.equal(head.status, 200, `expected 200 for device tunnel, got ${JSON.stringify(head)}`);
    const payload = randomBytes(256 * 1024);
    await s.write(payload);
    await s.finish();
    const gotChunks: Buffer[] = r.carry.length > 0 ? [r.carry] : [];
    let gotLen = r.carry.length;
    while (gotLen < payload.length) {
      const c = await s.read();
      if (c === null) break;
      gotChunks.push(c);
      gotLen += c.length;
    }
    const echoed = Buffer.concat(gotChunks);
    assert.equal(echoed.length, payload.length);
    assert.ok(echoed.equals(payload), "device tunnel echoed bytes mismatch");
  }

  // 2f. Live peer revocation (`on_cloud_changed` with `peers_current == true`) MUST immediately
  //     sever an active `device:` tunnel and close its upstream TCP socket!
  {
    const liveStream = await httpConn.openBi();
    await writeLine(liveStream, { workspace: "ws-edge", device: addedTcp.id, session: "s1", tcp: true });
    const lr = new Reader(liveStream, 65536);
    const lhead = (await lr.line()) as { status: number };
    assert.equal(lhead.status, 200);
    await liveStream.write(Buffer.from("ping-before-revoke"));
    const echoedPing = lr.carry.length > 0 ? lr.carry : (await liveStream.read()) ?? Buffer.alloc(0);
    assert.equal(echoedPing.toString("utf8"), "ping-before-revoke");
    assert.ok(openUpstreamSockets >= 1, "expected open upstream socket before revocation");

    // Push fresh cloud state with `peers: []` (revoking `peerId`).
    for (const ws of cloudSockets) {
      ws.send(
        JSON.stringify({
          type: "state",
          workspace: "ws-edge",
          workspace_name: "EdgeWS",
          name: "edge-station",
          peers: [],
          relay_urls: [],
          grant_keys: grantKeys,
        }),
      );
    }

    // Active stream MUST close immediately AND upstream TCP socket MUST be closed!
    let streamClosed = false;
    try {
      const next = await Promise.race([
        liveStream.read(),
        new Promise<string>((r) => setTimeout(() => r("TIMEOUT"), 5000)),
      ]);
      if (next === null) streamClosed = true;
    } catch {
      streamClosed = true;
    }
    assert.equal(streamClosed, true, "active device tunnel was NOT severed on live peer revocation");
    await until("upstream TCP socket closed on peer revocation", () => openUpstreamSockets === 0, 5000);
  }

  // 2g. `CLOSE_REMOVED` (4004) MUST also immediately sever any active `device:` tunnel and close
  //     its upstream TCP socket (even though `peers_current` becomes false on disconnect)!
  {
    // Re-add peer via fresh cloud `state` frame so we can open a new active tunnel.
    for (const ws of cloudSockets) {
      ws.send(
        JSON.stringify({
          type: "state",
          workspace: "ws-edge",
          workspace_name: "EdgeWS",
          name: "edge-station",
          peers: [{ id: peerId, name: "peer-caller", ips: ["127.0.0.1"] }],
          relay_urls: [],
          grant_keys: grantKeys,
        }),
      );
    }
    const remConn = await until("peer http conn ready for CLOSE_REMOVED", async () => {
      const c = await peerEp.connect({ id: stationId, relays: [], ips: [`127.0.0.1:${udpPort}`] }, PEER_HTTP_ALPN);
      try {
        const s = await c.openBi();
        await writeLine(s, { workspace: "ws-edge", device: addedTcp.id, session: "s2", tcp: true, probe: true });
        await s.finish();
        const r = new Reader(s, 65536);
        const h = (await r.line()) as { status: number };
        if (h.status === 200) return c;
      } catch {}
      c.close(0, "retry");
      return null;
    });
    const liveStream2 = await remConn.openBi();
    await writeLine(liveStream2, { workspace: "ws-edge", device: addedTcp.id, session: "s2", tcp: true });
    const lr2 = new Reader(liveStream2, 65536);
    const lhead2 = (await lr2.line()) as { status: number };
    assert.equal(lhead2.status, 200);
    await liveStream2.write(Buffer.from("ping-before-removed"));
    const echoed2 = lr2.carry.length > 0 ? lr2.carry : (await liveStream2.read()) ?? Buffer.alloc(0);
    assert.equal(echoed2.toString("utf8"), "ping-before-removed");
    assert.ok(openUpstreamSockets >= 1, "expected open upstream socket before CLOSE_REMOVED");

    // Close cloud WS with `CLOSE_REMOVED` (4004).
    for (const ws of cloudSockets) {
      if (ws.readyState === ws.OPEN) ws.close(4004, "removed");
    }

    let removedClosed = false;
    try {
      const next = await Promise.race([
        liveStream2.read(),
        new Promise<string>((r) => setTimeout(() => r("TIMEOUT"), 5000)),
      ]);
      if (next === null) removedClosed = true;
    } catch {
      removedClosed = true;
    }
    assert.equal(removedClosed, true, "active device tunnel was NOT severed on CLOSE_REMOVED (4004)");
    await until("upstream TCP socket closed on CLOSE_REMOVED", () => openUpstreamSockets === 0, 5000);
    remConn.close(0, "done");
  }

  httpConn.close(0, "done");
  await new Promise((r) => setTimeout(r, 150));
  const fdAfter = openFdCount(pionPid);
  if (fdBefore > 0 && fdAfter > 0) {
    assert.ok(fdAfter - fdBefore <= 6, `FD leak after device tunnels: before=${fdBefore} after=${fdAfter}`);
  }

  // Clean shutdown: launcher + pion exit cleanly with zero orphans.
  launcher.kill("SIGTERM");
  await until("edge launcher clean exit", () => launcher.exitCode !== null || launcher.signalCode !== null);
  await until("edge pion process exited", () => !isAlive(pionPid));
});

test("W17A.4: Offline / cloud-unreachable resilience (MCP + Drive + PEER_HTTP + AdminApi + SIGUSR2 handover)", async () => {
  const mesh = resolveMeshAddon();
  const { grantKeys, signMemberJwt } = makeGrantKeysAndSigner();

  const echoSrv = createNetServer((sock) => {
    sock.on("data", (c) => sock.write(c));
  });
  servers.push(echoSrv);
  await new Promise<void>((resolve) => echoSrv.listen(0, "127.0.0.1", () => resolve()));
  const echoPort = (echoSrv.address() as AddressInfo).port;

  const dir = freshDir("offline");
  const appDir = join(dir, "app");
  const dataDir = join(dir, "data");
  const driveRoot = join(dir, "drive");
  installReleaseDir(appDir, pionBin, readerBin, runnerBin, false);
  mkdirSync(join(dataDir, "mesh"), { recursive: true });
  mkdirSync(driveRoot, { recursive: true });

  const idRes = spawnSync(pionBin, ["id", "--data", dataDir], { encoding: "utf8" });
  assert.equal(idRes.status, 0, idRes.stderr);
  const stationId = idRes.stdout.trim();

  const clientEp = await bindClientEp(mesh);
  const clientId = clientEp.id();

  // Start a mock cloud presence server so the station connects once, receives its peer roster,
  // and then we shut down the cloud server completely to test full cloud-unreachable resilience!
  let cloudConnected = false;
  const cloudSrv = createHttpServer((_req, res) => {
    res.writeHead(200, { "content-type": "application/json" }).end("{}");
  });
  const cloudWss = new WebSocketServer({ noServer: true });
  servers.push(cloudWss, cloudSrv);
  const cloudSockets: import("ws").WebSocket[] = [];
  cloudSrv.on("upgrade", (req, socket, head) => {
    cloudWss.handleUpgrade(req, socket, head, (ws) => {
      cloudSockets.push(ws);
      cloudConnected = true;
      ws.on("message", (m) => {
        if (String(m) === "ping") ws.send("pong");
      });
      ws.send(
        JSON.stringify({
          type: "state",
          workspace: "ws-offline",
          workspace_name: "OfflineWS",
          name: "offline-station",
          peers: [{ id: clientId, name: "peer-off", ips: ["127.0.0.1"] }],
          relay_urls: [],
          grant_keys: grantKeys,
        }),
      );
    });
  });
  await new Promise<void>((resolve) => cloudSrv.listen(0, "127.0.0.1", () => resolve()));
  const cloudPort = (cloudSrv.address() as AddressInfo).port;

  writeFileSync(
    join(dataDir, "config.json"),
    JSON.stringify({ engine: "pion", drive: { roots: [driveRoot] } }),
  );
  writeFileSync(
    join(dataDir, "mesh", "cloud.json"),
    JSON.stringify({
      origin: `http://127.0.0.1:${cloudPort}`,
      workspace: "ws-offline",
      workspace_name: "OfflineWS",
      station: stationId,
      name: "offline-station",
      peers: [{ id: clientId, name: "peer-off", ips: ["127.0.0.1"] }],
      relay_urls: [],
      grant_keys: grantKeys,
    }),
  );

  const udpPort = await pickFreeUdpPort();
  const launcher = spawn(launcherBin, ["run", "--app", appDir, "--data", dataDir, "--port", "0"], {
    env: {
      ...process.env,
      STILLFAIL_NO_DISCOVERY: "1",
      STILLFAIL_NO_DHT: "1",
      STILLFAIL_MESH_BIND_ADDR: `127.0.0.1:${udpPort}`,
    },
    stdio: "ignore",
  });
  children.push(launcher);

  const pid1 = await until("offline pion pid", () => {
    const p = readHubPid(dataDir);
    return p > 0 && isAlive(p) ? p : null;
  });
  const mcpPort = await until("offline mcp port", () => readMcpPort(dataDir) || null);
  await until("cloud initial state delivered", () => cloudConnected);

  // Open `stillfail/http/1` once Pion has processed the cloud `state` frame (`peers_current = true`),
  // then kill cloud completely (simulating full cloud outage!).
  const httpConn = await until("httpConn accepted after cloud state", async () => {
    const c = await clientEp.connect({ id: stationId, relays: [], ips: [`127.0.0.1:${udpPort}`] }, PEER_HTTP_ALPN);
    try {
      const ps = await c.openBi();
      await writeLine(ps, { workspace: "ws-offline", port: echoPort, tcp: true, probe: true });
      await ps.finish();
      const pr = new Reader(ps, 65536);
      const ph = (await pr.line()) as { status: number };
      if (ph.status === 200) return c;
    } catch {}
    c.close(0, "retry");
    return null;
  });
  for (const ws of cloudSockets) ws.terminate();
  cloudWss.close();
  cloudSrv.closeAllConnections();
  await new Promise<void>((resolve) => cloudSrv.close(() => resolve()));

  // 1. AdminApi (`/status` + Drive upload/read + create session to get MCP token) works completely offline.
  const jwt = signMemberJwt({
    ws: "ws-offline",
    device: clientId,
    sub: "u-off",
    email: "off@example.com",
    name: "OfflineUser",
    role: "owner",
  });
  const { conn: adminConn } = await until("offline admin connect", () =>
    openAdminConn(clientEp, stationId, `127.0.0.1:${udpPort}`, jwt),
  );
  const stResp = await adminRequest(adminConn, "GET", "/status");
  assert.equal(stResp.status, 200);

  const upBody = Buffer.from("offline-drive-payload-12345");
  const upResp = await adminRequest(
    adminConn,
    "PUT",
    `/drive/upload?root=${encodeURIComponent(driveRoot)}&path=hello.txt&id=up-off-1&offset=0&total=${upBody.length}`,
    [],
    upBody,
  );
  assert.equal(upResp.status, 200, upResp.body.toString("utf8"));
  const rdResp = await adminRequest(
    adminConn,
    "GET",
    `/drive/read?root=${encodeURIComponent(driveRoot)}&path=hello.txt`,
  );
  assert.equal(rdResp.status, 200);
  assert.equal(rdResp.body.toString("utf8"), "offline-drive-payload-12345");

  // Create a session to obtain a Bearer token for local MCP check.
  const createSess = await adminRequest(
    adminConn,
    "POST",
    "/sessions",
    [["content-type", "application/json"]],
    JSON.stringify({ key: "sess-offline-1", title: "OfflineChat", runtime: "claude", cwd: dir }),
  );
  assert.equal(createSess.status, 200, createSess.body.toString("utf8"));
  const tokDb = new DatabaseSync(join(dataDir, "stillfail.db"), { readOnly: true });
  const tokRow = tokDb.prepare("SELECT token FROM sessions WHERE key = ?").get("sess-offline-1") as { token: string } | undefined;
  tokDb.close();
  const mcpToken = tokRow?.token ?? "";
  assert.ok(mcpToken && mcpToken.length >= 32, `expected MCP bearer token, got: ${mcpToken}`);

  // 2. Local MCP works offline.
  const mcpResp = await httpCall(
    mcpPort,
    "POST",
    "/mcp",
    {
      host: `127.0.0.1:${mcpPort}`,
      authorization: `Bearer ${mcpToken}`,
      "content-type": "application/json",
    },
    JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "chat_list", arguments: {} } }),
  );
  assert.equal(mcpResp.status, 200, mcpResp.body);
  assert.ok(mcpResp.body.includes("OfflineChat"), `expected OfflineChat in MCP chat_list: ${mcpResp.body}`);

  // 3. `stillfail/http/1` keeps working seamlessly while cloud is unreachable!
  const ts = await httpConn.openBi();
  await writeLine(ts, { workspace: "ws-offline", port: echoPort, tcp: true });
  const tr = new Reader(ts, 65536);
  const thead = (await tr.line()) as { status: number };
  assert.equal(thead.status, 200);
  await ts.write(Buffer.from("offline-tcp-ok"));
  await ts.finish();
  const echoBuf = tr.carry.length > 0 ? tr.carry : (await ts.read()) ?? Buffer.alloc(0);
  assert.equal(echoBuf.toString("utf8"), "offline-tcp-ok");
  httpConn.close(0, "done");
  adminConn.close(0, "done");

  // 4. `SIGUSR2` handover succeeds completely offline!
  launcher.kill("SIGUSR2");
  const pid2 = await until("offline handover new pid", () => {
    const p = readHubPid(dataDir);
    return p > 0 && p !== pid1 && isAlive(p) ? p : null;
  });
  assert.notEqual(pid2, pid1);

  launcher.kill("SIGTERM");
  await until("offline launcher exit", () => launcher.exitCode !== null || launcher.signalCode !== null);
});

test("W17A.5: Astra R9 P2 regressions (offset gap no '万', active UTF-8 no U+FFFD, PRAGMA user_version=1 16 MiB trim)", async () => {
  const mesh = resolveMeshAddon();
  const { grantKeys, signMemberJwt } = makeGrantKeysAndSigner();

  const dir = freshDir("r9-p2");
  const appDir = join(dir, "app");
  const dataDir = join(dir, "data");
  installReleaseDir(appDir, pionBin, readerBin, runnerBin, false);
  mkdirSync(join(dataDir, "mesh"), { recursive: true });
  mkdirSync(join(dataDir, "run", "runners"), { recursive: true });

  const idRes = spawnSync(pionBin, ["id", "--data", dataDir], { encoding: "utf8" });
  assert.equal(idRes.status, 0, idRes.stderr);
  const stationId = idRes.stdout.trim();

  writeFileSync(join(dataDir, "config.json"), JSON.stringify({ engine: "pion" }));
  writeFileSync(
    join(dataDir, "mesh", "cloud.json"),
    JSON.stringify({
      workspace: "ws-r9",
      workspace_name: "R9WS",
      station: stationId,
      name: "r9-station",
      peers: [],
      relay_urls: [],
      grant_keys: grantKeys,
    }),
  );

  // 1. Seed a legacy `user_version = 0` `<data>/run/adopted-runners.db` with:
  //    - `sess-gap`: offset gap [23,38) ending in 0xE4 0xB8 ("中"[0..2]) -> [52,66) starting with 0x87 ("文"[2..3])
  //    - `sess-trim`: 17 MiB of chunks with intentionally stale/missing `runner_session_totals`
  const adoptedDbPath = join(dataDir, "run", "adopted-runners.db");
  const adb = new DatabaseSync(adoptedDbPath);
  adb.exec(`
    PRAGMA journal_mode=WAL;
    PRAGMA user_version=0;
    CREATE TABLE IF NOT EXISTS runner_instances (
      instance_id TEXT PRIMARY KEY,
      session_key TEXT NOT NULL,
      runner_id TEXT NOT NULL,
      runner_pid INTEGER NOT NULL,
      started_at INTEGER NOT NULL,
      acked_out INTEGER NOT NULL DEFAULT 0,
      acked_err INTEGER NOT NULL DEFAULT 0,
      updated_at INTEGER NOT NULL
    );
    CREATE TABLE IF NOT EXISTS runner_output (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_key TEXT NOT NULL,
      instance_id TEXT NOT NULL,
      stream TEXT NOT NULL,
      start_off INTEGER NOT NULL,
      end_off INTEGER NOT NULL,
      byte_len INTEGER NOT NULL,
      data_b64 TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_runner_output_session ON runner_output(session_key, id);
    CREATE TABLE IF NOT EXISTS runner_session_totals (
      session_key TEXT PRIMARY KEY,
      total_bytes INTEGER NOT NULL DEFAULT 0
    );
  `);
  const chunk1 = Buffer.concat([Buffer.from("prefix-012345"), Buffer.from([0xe4, 0xb8])]); // 15 bytes: [23, 38)
  const chunk2 = Buffer.concat([Buffer.from([0x87]), Buffer.from("-suffix-01234")]); // 14 bytes: [52, 66)
  const ins = adb.prepare(
    "INSERT INTO runner_output (session_key, instance_id, stream, start_off, end_off, byte_len, data_b64) VALUES (?, ?, ?, ?, ?, ?, ?)",
  );
  ins.run("sess-gap", "inst-gap:1:1", "out", 23, 38, chunk1.length, chunk1.toString("base64"));
  ins.run("sess-gap", "inst-gap:1:1", "out", 52, 66, chunk2.length, chunk2.toString("base64"));

  // Insert 17 MiB (17 x 1 MiB chunks) into `sess-trim` with NO row in `runner_session_totals`.
  const oneMb = Buffer.alloc(1024 * 1024, 0x41);
  const oneMbB64 = oneMb.toString("base64");
  adb.exec("BEGIN IMMEDIATE;");
  for (let i = 0; i < 17; i++) {
    ins.run("sess-trim", "inst-trim:2:1", "out", i * oneMb.length, (i + 1) * oneMb.length, oneMb.length, oneMbB64);
  }
  adb.exec("COMMIT;");
  adb.close();

  // 2. Spawn a live `stillfail-runner` for `sess-live` that writes "中"[0..2] (0xE4 0xB8),
  //    waits on a gate file while staying active, then writes "中"[2..3] (0xAD) and exits.
  const utf8Gate = join(dir, "utf8-finish.gate");
  const liveRunnerId = "claude-sess-live";
  const liveRunnerSock = join(dataDir, "run", "runners", `${liveRunnerId}.sock`);
  const liveScript = join(dir, "split-utf8.sh");
  writeFileSync(
    liveScript,
    `#!/bin/sh
printf '\\344\\270'
while [ ! -f ${JSON.stringify(utf8Gate)} ]; do sleep 0.05; done
printf '\\255'
exit 0
`,
  );
  chmodSync(liveScript, 0o755);

  const liveRunnersDir = join(dataDir, "run", "runners");
  const liveRunnerProc = spawn(
    runnerBin,
    ["--dir", liveRunnersDir, "--id", liveRunnerId, "--cwd", dir, "--", "/bin/sh", liveScript],
    { stdio: "ignore", detached: true },
  );
  if (liveRunnerProc.pid) extraPids.push(liveRunnerProc.pid);
  await until(
    "live utf8 runner socket",
    () => existsSync(liveRunnerSock) && existsSync(join(liveRunnersDir, `${liveRunnerId}.json`)),
  );
  const liveRunnerMeta = JSON.parse(readFileSync(join(liveRunnersDir, `${liveRunnerId}.json`), "utf8"));
  if (typeof liveRunnerMeta.runner === "number") extraPids.push(liveRunnerMeta.runner);
  if (typeof liveRunnerMeta.pgid === "number") extraPids.push(liveRunnerMeta.pgid);

  // Boot Pion briefly once to initialize the exact production `stillfail.db` schema, create
  // the 3 sessions via AdminApi, then stop it so we can seed legacy `user_version = 0`
  // `adopted-runners.db` + live runner attachment cleanly.
  const udpPort = await pickFreeUdpPort();
  const initLauncher = spawn(launcherBin, ["run", "--app", appDir, "--data", dataDir, "--port", "0"], {
    env: {
      ...process.env,
      STILLFAIL_NO_DISCOVERY: "1",
      STILLFAIL_NO_DHT: "1",
      STILLFAIL_MESH_BIND_ADDR: `127.0.0.1:${udpPort}`,
    },
    stdio: "ignore",
  });
  children.push(initLauncher);
  await until("r9 init pion pid", () => {
    const p = readHubPid(dataDir);
    return p > 0 && isAlive(p) ? p : null;
  });
  const clientEp = await bindClientEp(mesh);
  const jwt = signMemberJwt({
    ws: "ws-r9",
    device: clientEp.id(),
    sub: "u-r9",
    email: "r9@example.com",
    name: "R9",
    role: "owner",
  });
  const { conn: initConn } = await until("r9 init admin connect", () =>
    openAdminConn(clientEp, stationId, `127.0.0.1:${udpPort}`, jwt),
  );
  for (const [k, title] of [["sess-gap", "GapTest"], ["sess-trim", "TrimTest"], ["sess-live", "LiveUtf8Test"]]) {
    const r = await adminRequest(
      initConn,
      "POST",
      "/sessions",
      [["content-type", "application/json"]],
      JSON.stringify({ key: k, title, runtime: "claude", cwd: dir }),
    );
    assert.equal(r.status, 200, r.body.toString("utf8"));
  }
  initConn.close(0, "init-done");
  initLauncher.kill("SIGTERM");
  await until("r9 init launcher exit", () => initLauncher.exitCode !== null || initLauncher.signalCode !== null);

  // Now start Pion over the legacy `user_version = 0` `adopted-runners.db` + live runner!
  const launcher = spawn(launcherBin, ["run", "--app", appDir, "--data", dataDir, "--port", "0"], {
    env: {
      ...process.env,
      STILLFAIL_NO_DISCOVERY: "1",
      STILLFAIL_NO_DHT: "1",
      STILLFAIL_MESH_BIND_ADDR: `127.0.0.1:${udpPort}`,
      STILLFAIL_DRIVE_ROOTS: dir,
    },
    stdio: "ignore",
  });
  children.push(launcher);

  await until("r9 pion pid", () => {
    const p = readHubPid(dataDir);
    return p > 0 && isAlive(p) ? p : null;
  });

  const { conn } = await until("r9 admin connect", () =>
    openAdminConn(clientEp, stationId, `127.0.0.1:${udpPort}`, jwt),
  );

  // Check 1: Offset gap `[23,38) -> [52,66)` MUST NOT produce `"万"`!
  const gapResp = await adminRequest(conn, "GET", "/sessions/sess-gap");
  assert.equal(gapResp.status, 200, gapResp.body.toString("utf8"));
  const gapOut = (JSON.parse(gapResp.body.toString("utf8")).adoptedOutput as string[]).join("");
  assert.ok(gapOut.includes("prefix-012345"), `expected prefix in gapOut: ${gapOut}`);
  assert.ok(gapOut.includes("-suffix-01234"), `expected suffix in gapOut: ${gapOut}`);
  assert.ok(!gapOut.includes("万"), `offset gap must never stitch bogus '万', got: ${gapOut}`);

  // Check 2: Active runner with 2-byte incomplete UTF-8 ("中"[0..2]) MUST NOT emit U+FFFD!
  // Wait until the 2-byte chunk has been committed to `adopted-runners.db`.
  await until("sess-live 2-byte chunk committed", () => {
    const checkDb = new DatabaseSync(adoptedDbPath, { readOnly: true });
    try {
      const row = checkDb
        .prepare("SELECT COUNT(*) AS cnt FROM runner_output WHERE session_key = 'sess-live'")
        .get() as { cnt: number };
      return row.cnt >= 1;
    } finally {
      checkDb.close();
    }
  });
  const liveMidResp = await adminRequest(conn, "GET", "/sessions/sess-live");
  assert.equal(liveMidResp.status, 200);
  const liveMidOut = (JSON.parse(liveMidResp.body.toString("utf8")).adoptedOutput as string[]).join("");
  assert.ok(!liveMidOut.includes("\uFFFD"), `active runner must not emit U+FFFD for valid incomplete tail, got: ${JSON.stringify(liveMidOut)}`);

  // Release the 3rd byte (`0xAD`) + exit -> now `"中"` completes cleanly with zero U+FFFD!
  writeFileSync(utf8Gate, "finish\n");
  const liveDoneOut = await until("sess-live completed '中'", async () => {
    const r = await adminRequest(conn, "GET", "/sessions/sess-live");
    if (r.status !== 200) return null;
    const joined = (JSON.parse(r.body.toString("utf8")).adoptedOutput as string[]).join("");
    return joined.includes("中") ? joined : null;
  });
  assert.equal(liveDoneOut, "中");
  assert.ok(!liveDoneOut.includes("\uFFFD"));

  // Check 3: `PRAGMA user_version = 1` migration recomputed `runner_session_totals` and trimmed `sess-trim` <= 16 MiB!
  const verifyDb = new DatabaseSync(adoptedDbPath, { readOnly: true });
  const uv = verifyDb.prepare("PRAGMA user_version").get() as { user_version: number };
  assert.equal(uv.user_version, 1, `expected PRAGMA user_version = 1, got ${uv.user_version}`);
  const trimRow = verifyDb
    .prepare("SELECT total_bytes FROM runner_session_totals WHERE session_key = 'sess-trim'")
    .get() as { total_bytes: number } | undefined;
  const actualSum = verifyDb
    .prepare("SELECT COALESCE(SUM(byte_len), 0) AS s FROM runner_output WHERE session_key = 'sess-trim'")
    .get() as { s: number };
  verifyDb.close();
  assert.ok(trimRow !== undefined, "runner_session_totals row for sess-trim missing after v1 migration");
  assert.equal(trimRow.total_bytes, actualSum.s, "runner_session_totals must equal exact SUM(byte_len)");
  assert.ok(trimRow.total_bytes <= 16 * 1024 * 1024, `sess-trim must be <= 16 MiB after migration, got ${trimRow.total_bytes}`);
  assert.ok(trimRow.total_bytes > 0, "sess-trim must retain recent chunks within 16 MiB window");

  conn.close(0, "done");
  launcher.kill("SIGTERM");
  await until("r9 launcher exit", () => launcher.exitCode !== null || launcher.signalCode !== null);
});

test("W17A.6: Node takeBackSoon vs Pion differential parity (complete, notEmpty, missing head.json + restart liveness)", async () => {
  const mesh = resolveMeshAddon();
  const { grantKeys, signMemberJwt } = makeGrantKeysAndSigner();

  // Export one real snapshot from a Node Store to reuse across all 3 differential scenarios.
  const srcDir = freshDir("replica-src");
  const srcDb = join(srcDir, "stillfail.db");
  const srcStore = Store.open(srcDb, join(srcDir, "archive"));
  const ws = "ws-restore";
  const nowMs = Date.now();
  srcStore.db
    .prepare(
      "INSERT INTO sessions (key, connect, scope, title, runtime, profile, workspace, token, created_at, last_active_at, cwd, ws) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
    )
    .run("chat:a", "chat", "chat:a", "RestoredFromNode", "claude", "default", srcDir, randomBytes(32).toString("hex"), nowMs, nowMs, srcDir, null);
  srcStore.db
    .prepare("INSERT INTO threads (id, surface, channel, thread_ts, title, created_at) VALUES (?, ?, ?, ?, ?, ?)")
    .run(1, "web", "CHAT", "1.000", "RestoredFromNode", nowMs);
  srcStore.db
    .prepare("INSERT INTO thread_sessions (thread, session, connect, joined_at) VALUES (?, ?, ?, ?)")
    .run(1, "chat:a", "chat", nowMs);
  srcStore.db
    .prepare("INSERT INTO entries (thread, n, kind, author_kind, author, text, at) VALUES (?, ?, 'message', 'person', ?, ?, ?)")
    .run(1, 1, "alice@example.com", "hello-before-restore", nowMs);

  const originId = "a".repeat(64);
  const exp = new Exporter({ db: srcDb, replica: join(srcDir, "replica"), dataDir: srcDir, origin: originId, now: () => nowMs });
  exp.setPlaces({ home: ws, workspaces: [{ workspace: ws, name: "src-laptop" }] });
  let passRes = exp.pass(nothingTold());
  while (passRes.more) passRes = exp.pass(nothingTold());
  const head = passRes.heads[ws];
  assert.ok(head, "expected Exporter head for workspace");
  const genPath = genDir(ownDir(join(srcDir, "replica")), ws, head.gen);
  const filesSrcDir = join(srcDir, "exported-files");
  mkdirSync(filesSrcDir, { recursive: true });
  for (const hash of Object.keys(head.files)) {
    const p = exp.sourceOf(hash);
    if (p) copyFileSync(p, join(filesSrcDir, hash));
  }
  exp.close();
  srcStore.close();

  const stageRestore = (dataDir: string, dropHead: boolean): void => {
    const copyDir = join(dataDir, "restore", "copy");
    mkdirSync(copyDir, { recursive: true });
    cpSync(genPath, join(copyDir, head.gen), { recursive: true });
    cpSync(filesSrcDir, join(copyDir, "files"), { recursive: true });
    if (dropHead) rmSync(join(copyDir, head.gen, "head.json"));
    writeFileSync(
      join(dataDir, "restore", "ready.json"),
      JSON.stringify({ origin: originId, workspace: ws, gen: head.gen, name: "src-laptop", from: "peer-1" }),
    );
  };

  const setupPionDir = (tag: string): { appDir: string; dataDir: string; stationId: string } => {
    const d = freshDir(tag);
    const appDir = join(d, "app");
    const dataDir = join(d, "data");
    installReleaseDir(appDir, pionBin, readerBin, runnerBin, false);
    mkdirSync(join(dataDir, "mesh"), { recursive: true });
    writeFileSync(join(dataDir, "config.json"), JSON.stringify({ engine: "pion" }));
    const idRes = spawnSync(pionBin, ["id", "--data", dataDir], { encoding: "utf8" });
    assert.equal(idRes.status, 0, idRes.stderr);
    const stationId = idRes.stdout.trim();
    writeFileSync(
      join(dataDir, "mesh", "cloud.json"),
      JSON.stringify({
        workspace: ws,
        workspace_name: "RestoreWS",
        station: stationId,
        name: `restore-${tag}`,
        peers: [],
        relay_urls: [],
        grant_keys: grantKeys,
      }),
    );
    return { appDir, dataDir, stationId };
  };

  const runPionOnce = async (appDir: string, dataDir: string): Promise<{ udpPort: number; stop: () => Promise<void> }> => {
    const udpPort = await pickFreeUdpPort();
    const launcher = spawn(launcherBin, ["run", "--app", appDir, "--data", dataDir, "--port", "0"], {
      env: { ...process.env, STILLFAIL_NO_DISCOVERY: "1", STILLFAIL_NO_DHT: "1", STILLFAIL_MESH_BIND_ADDR: `127.0.0.1:${udpPort}` },
      stdio: "ignore",
    });
    children.push(launcher);
    await until("pion pid alive", () => {
      const p = readHubPid(dataDir);
      return p > 0 && isAlive(p) ? p : null;
    });
    const adminPort = await until("pion loopback port", () => readPorts(dataDir).admin || null);
    const hz = await httpCall(adminPort, "GET", "/healthz");
    assert.equal(hz.status, 200);
    return {
      udpPort,
      stop: async () => {
        launcher.kill("SIGTERM");
        await until("launcher exit", () => launcher.exitCode !== null || launcher.signalCode !== null);
      },
    };
  };

  // --- Scenario 1: Complete snapshot (Node takeBackSoon vs Pion --internal-replica-restore + native Pion Launcher boot) ---
  {
    // Node side
    const nodeDir = freshDir("replica-node-ok");
    const nodeDb = join(nodeDir, "stillfail.db");
    Store.open(nodeDb, join(nodeDir, "archive")).close();
    stageRestore(nodeDir, false);
    await takeBackSoon(nodeDir, nodeDb, nowMs, readerBin);
    const nodeOut = JSON.parse(readFileSync(join(nodeDir, "replica", "restored.json"), "utf8"));
    assert.equal(nodeOut.error, null);
    assert.equal(existsSync(join(nodeDir, "restore")), false, "Node must clean <data>/restore/");

    // Pion `--internal-replica-restore` differential parity + subsequent native Pion Launcher boot
    const { appDir, dataDir, stationId } = setupPionDir("replica-pion-ok");
    stageRestore(dataDir, false);
    const restRes = spawnSync(
      pionBin,
      ["--internal-replica-restore", "--db", join(dataDir, "stillfail.db"), "--data", dataDir, "--now", String(nowMs)],
      { encoding: "utf8", timeout: 20_000 },
    );
    assert.equal(restRes.status, 0, restRes.stderr);
    const pionOut = JSON.parse(readFileSync(join(dataDir, "replica", "restored.json"), "utf8"));
    assert.equal(pionOut.error, nodeOut.error, "Pion vs Node complete-restore error parity");
    assert.equal(pionOut.reason, nodeOut.reason, "Pion vs Node complete-restore reason parity");
    assert.equal(existsSync(join(dataDir, "restore")), false, "Pion must clean <data>/restore/");

    // Pure-Web restored dataDir boots natively on Pion via real Launcher and serves `chat:a`!
    const run = await runPionOnce(appDir, dataDir);
    const clientEp = await bindClientEp(mesh);
    const jwt = signMemberJwt({ ws, device: clientEp.id(), sub: "u-rest", email: "alice@example.com", name: "Alice", role: "owner" });
    const { conn } = await until("restore admin connect", () => openAdminConn(clientEp, stationId, `127.0.0.1:${run.udpPort}`, jwt));
    const chatsResp = await adminRequest(conn, "GET", "/chats");
    assert.equal(chatsResp.status, 200, chatsResp.body.toString("utf8"));
    assert.ok(chatsResp.body.toString("utf8").includes("RestoredFromNode"));
    conn.close(0, "done");
    await run.stop();
  }

  // --- Scenario 2: Non-empty DB (`notEmpty`) — Node vs Pion parity, zero orphan ready.json, normal boot ---
  {
    const seedExisting = (dbPath: string, archDir: string): void => {
      const s = Store.open(dbPath, archDir);
      s.db.prepare("INSERT INTO threads (id, surface, channel, thread_ts, title, created_at) VALUES (1, 'web', 'CHAT', '9.000', 'ExistingLocalThread', ?)").run(nowMs);
      s.close();
    };
    const nodeDir = freshDir("replica-node-notempty");
    const nodeDb = join(nodeDir, "stillfail.db");
    seedExisting(nodeDb, join(nodeDir, "archive"));
    stageRestore(nodeDir, false);
    await takeBackSoon(nodeDir, nodeDb, nowMs, readerBin);
    const nodeOut = JSON.parse(readFileSync(join(nodeDir, "replica", "restored.json"), "utf8"));
    assert.equal(nodeOut.reason, "notEmpty");
    assert.equal(existsSync(join(nodeDir, "restore")), false);

    const { appDir, dataDir } = setupPionDir("replica-pion-notempty");
    seedExisting(join(dataDir, "stillfail.db"), join(dataDir, "archive"));
    stageRestore(dataDir, false);
    const restRes = spawnSync(
      pionBin,
      ["--internal-replica-restore", "--db", join(dataDir, "stillfail.db"), "--data", dataDir, "--now", String(nowMs)],
      { encoding: "utf8", timeout: 20_000 },
    );
    assert.equal(restRes.status, 0, restRes.stderr);
    const pionOut = JSON.parse(readFileSync(join(dataDir, "replica", "restored.json"), "utf8"));
    assert.equal(pionOut.reason, nodeOut.reason, "Pion vs Node notEmpty reason parity");
    assert.equal(existsSync(join(dataDir, "restore")), false, "Pion must leave no orphan ready.json on notEmpty");
    const run = await runPionOnce(appDir, dataDir);
    await run.stop();

    const checkStore = Store.open(join(dataDir, "stillfail.db"), join(dataDir, "archive"));
    assert.ok(checkStore.threadAt("web", "CHAT", "9.000") !== null, "existing local thread must be preserved");
    checkStore.close();
  }

  // --- Scenario 3: Missing `head.json` — Node vs Pion parity, clean `<data>/restore/`, 1st & 2nd boot both healthy ---
  {
    const nodeDir = freshDir("replica-node-badhead");
    const nodeDb = join(nodeDir, "stillfail.db");
    Store.open(nodeDb, join(nodeDir, "archive")).close();
    stageRestore(nodeDir, true);
    await takeBackSoon(nodeDir, nodeDb, nowMs, readerBin);
    const nodeOut = JSON.parse(readFileSync(join(nodeDir, "replica", "restored.json"), "utf8"));
    assert.ok(typeof nodeOut.error === "string" && nodeOut.error.length > 0, "Node must record non-empty error");
    assert.equal(existsSync(join(nodeDir, "restore")), false);

    const { appDir, dataDir } = setupPionDir("replica-pion-badhead");
    stageRestore(dataDir, true);
    spawnSync(
      pionBin,
      ["--internal-replica-restore", "--db", join(dataDir, "stillfail.db"), "--data", dataDir, "--now", String(nowMs)],
      { encoding: "utf8", timeout: 20_000 },
    );
    const pionOut = JSON.parse(readFileSync(join(dataDir, "replica", "restored.json"), "utf8"));
    assert.ok(typeof pionOut.error === "string" && pionOut.error.length > 0, "Pion must record non-empty error");
    assert.equal(pionOut.reason, nodeOut.reason, "Pion vs Node corrupt-head reason parity");
    assert.equal(existsSync(join(dataDir, "restore")), false, "Pion must leave no orphan ready.json on missing head.json");
    const run1 = await runPionOnce(appDir, dataDir);
    await run1.stop();

    // Second restart in the SAME dataDir MUST also boot cleanly (zero boot-loop bricking)!
    const run2 = await runPionOnce(appDir, dataDir);
    await run2.stop();
  }
});

// (Wave 17A.7 temporary Node fallback entry gate test removed in Wave 17C-1: external connects run natively on Pion.)

test("W17B-5.7: Pure Pion native external connects (Slack + Comma + cross-station connect.event + comma.read_file + native replica restore, zero Node fallback)", async () => {
  const mesh = resolveMeshAddon();
  const { grantKeys, signMemberJwt } = makeGrantKeysAndSigner();

  async function peerRpc(
    ep: Endpoint,
    stationId: string,
    addr: string,
    workspace: string,
    request: Record<string, unknown>,
  ): Promise<any> {
    const conn = await ep.connect({ id: stationId, relays: [], ips: [addr] }, PEER_BYTES_ALPN);
    try {
      const stream = await conn.openBi();
      await stream.write(Buffer.from(JSON.stringify({ workspace, request }) + "\n"));
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
      const parsed = JSON.parse(headerStr);
      if ("error" in parsed) throw new Error(String(parsed.error));
      return parsed;
    } finally {
      await conn.close(0, "done");
    }
  }

  // --- Scenario 1: Pure Pion Slack Socket Mode + Comma WS end-to-end (withRealNodeMain = false!) ---
  {
    const slackPosted: string[] = [];
    const slackAcked: string[] = [];
    let slackClientWs: any = null;
    const slackSrv = createHttpServer((req, res) => {
      const chunks: Buffer[] = [];
      req.on("data", (c) => chunks.push(c));
      req.on("end", () => {
        const bodyStr = Buffer.concat(chunks).toString("utf8");
        if (req.url?.includes("auth.test")) {
          res.writeHead(200, { "content-type": "application/json" }).end(
            JSON.stringify({ ok: true, team_id: "T_W17B5", team: "W17B5Team", user_id: "UBOT_B5", bot_id: "BBOT_B5", user: "b5bot" }),
          );
          return;
        }
        if (req.url?.includes("apps.connections.open")) {
          const port = (slackSrv.address() as AddressInfo).port;
          res.writeHead(200, { "content-type": "application/json" }).end(
            JSON.stringify({ ok: true, url: `ws://127.0.0.1:${port}/slack-ws` }),
          );
          return;
        }
        if (req.url?.includes("chat.postMessage")) {
          slackPosted.push(bodyStr);
          res.writeHead(200, { "content-type": "application/json" }).end(
            JSON.stringify({ ok: true, ts: "1700.999" }),
          );
          return;
        }
        res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ ok: true }));
      });
    });
    const slackWss = new WebSocketServer({ noServer: true });
    servers.push(slackWss, slackSrv);
    slackSrv.on("upgrade", (req, socket, head) => {
      slackWss.handleUpgrade(req, socket, head, (ws) => {
        slackClientWs = ws;
        ws.on("message", (d) => {
          try {
            const msg = JSON.parse(String(d));
            if (typeof msg.envelope_id === "string") slackAcked.push(msg.envelope_id);
          } catch {}
        });
        ws.send(JSON.stringify({ type: "hello", num_connections: 1 }));
      });
    });
    await new Promise<void>((resolve) => slackSrv.listen(0, "127.0.0.1", () => resolve()));
    const slackPort = (slackSrv.address() as AddressInfo).port;

    // Mock Comma WS server
    let commaClientWs: any = null;
    const commaFrames: any[] = [];
    const commaSrv = createHttpServer((_req, res) => { res.writeHead(404).end(); });
    const commaWss = new WebSocketServer({ server: commaSrv });
    servers.push(commaWss, commaSrv);
    commaWss.on("connection", (ws) => {
      commaClientWs = ws;
      ws.on("message", (d) => {
        try { commaFrames.push(JSON.parse(String(d))); } catch {}
      });
      ws.send(JSON.stringify({ type: "connected", device_id: "dev-b5" }));
    });
    await new Promise<void>((resolve) => commaSrv.listen(0, "127.0.0.1", () => resolve()));
    const commaPort = (commaSrv.address() as AddressInfo).port;

    const dir = freshDir("w17b5-native-connects");
    const appDir = join(dir, "app");
    const dataDir = join(dir, "data");
    // withRealNodeMain = false: main.js exits 99 -> PROVES 100% pure Pion!
    installReleaseDir(appDir, pionBin, readerBin, runnerBin, false);
    mkdirSync(join(dataDir, "mesh"), { recursive: true });
    const idRes = spawnSync(pionBin, ["id", "--data", dataDir], { encoding: "utf8" });
    assert.equal(idRes.status, 0, idRes.stderr);
    const stationId = idRes.stdout.trim();

    writeFileSync(
      join(dataDir, "config.json"),
      JSON.stringify({
        engine: "pion",
        connects: [
          {
            id: "slack-b5",
            bind: { runtime: "claude" },
            slack: { appToken: "xapp-1-b5", botToken: "xoxb-b5", baseUrl: `http://127.0.0.1:${slackPort}` },
          },
          {
            id: "comma-b5",
            kind: "comma",
            bind: { runtime: "claude" },
            comma: { server: `http://127.0.0.1:${commaPort}`, token: "tok-b5", name: "b5-mac", instanceId: "inst-b5" },
          },
        ],
      }),
    );
    writeFileSync(
      join(dataDir, "mesh", "cloud.json"),
      JSON.stringify({
        workspace: "ws-b5",
        workspace_name: "B5WS",
        station: stationId,
        name: "b5-station",
        peers: [],
        relay_urls: [],
        grant_keys: grantKeys,
      }),
    );

    const udpPort = await pickFreeUdpPort();
    const launcher = spawn(launcherBin, ["run", "--app", appDir, "--data", dataDir, "--port", "0"], {
      env: { ...process.env, STILLFAIL_NO_DISCOVERY: "1", STILLFAIL_NO_DHT: "1", STILLFAIL_MESH_BIND_ADDR: `127.0.0.1:${udpPort}` },
      stdio: "ignore",
    });
    children.push(launcher);

    const pionPid = await until("W17B-5 pure Pion pid", () => {
      const p = readHubPid(dataDir);
      return p > 0 && isAlive(p) && readProcCmdline(p).includes("stillfail-station-pion") ? p : null;
    }, 25_000);
    assert.match(readProcCmdline(pionPid), /stillfail-station-pion/);

    await until("Slack & Comma WS connected to pure Pion", () => slackClientWs && commaClientWs ? true : null, 15_000);
    await until("Comma task.hello with task_read_file: 1", () =>
      commaFrames.find((f) => f.method === "task.hello" && f.params?.task_read_file === 1) ?? null,
    10_000);

    // Check /status reports live connects
    const clientEp = await bindClientEp(mesh);
    const jwt = signMemberJwt({ ws: "ws-b5", device: clientEp.id(), sub: "u-b5", email: "b5@example.com", name: "B5", role: "owner" });
    const { conn } = await until("W17B-5 admin connect", () => openAdminConn(clientEp, stationId, `127.0.0.1:${udpPort}`, jwt));
    const stJson = JSON.parse((await adminRequest(conn, "GET", "/status")).body.toString("utf8"));
    assert.equal(stJson.edge?.connects?.enabledInConfig, 2);
    assert.equal(stJson.edge?.connects?.total, 2);
    assert.equal(stJson.edge?.connects?.running, 2);
    conn.close(0, "done");

    // 1a. Push inbound Slack @bot message -> verify ACK + SQLite entries/deliveries + outbound MCP chat_post!
    slackClientWs.send(JSON.stringify({
      type: "events_api",
      envelope_id: "env-b5-1",
      payload: {
        event_id: "EvB5_1",
        event: { type: "app_mention", channel: "C_B5", ts: "1700.100", thread_ts: "1700.100", user: "U_ALICE", text: "<@UBOT_B5> hello pion hub" },
      },
    }));
    await until("Slack envelope env-b5-1 ACKed", () => slackAcked.includes("env-b5-1") ? true : null, 10_000);

    // Push Slack message_changed edit
    slackClientWs.send(JSON.stringify({
      type: "events_api",
      envelope_id: "env-b5-2",
      payload: {
        event_id: "EvB5_2",
        event: {
          type: "message",
          subtype: "message_changed",
          channel: "C_B5",
          event_ts: "1700.101",
          message: { type: "message", user: "U_ALICE", ts: "1700.100", thread_ts: "1700.100", text: "<@UBOT_B5> hello pion hub edited" },
        },
      },
    }));
    await until("Slack edit envelope env-b5-2 ACKed", () => slackAcked.includes("env-b5-2") ? true : null, 10_000);

    // Call /mcp chat_post using the created Slack session token -> verify outbound Slack chat.postMessage!
    const mcpPort = await until("W17B-5 mcp port", () => readMcpPort(dataDir) || null, 10_000);
    const slackSessRow = await until("Slack session row in stillfail.db", () => {
      const ro = new DatabaseSync(join(dataDir, "stillfail.db"), { readOnly: true });
      try {
        return ro.prepare("SELECT key, token FROM sessions WHERE connect = ? LIMIT 1").get("slack-b5") as { key: string; token: string } | undefined;
      } finally {
        ro.close();
      }
    }, 10_000);
    const mcpRes = await httpCall(
      mcpPort,
      "POST",
      "/mcp",
      { "content-type": "application/json", authorization: `Bearer ${slackSessRow.token}` },
      JSON.stringify({
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: { name: "chat_post", arguments: { to: "C_B5/1700.100", text: "reply-from-pion-mcp" } },
      }),
    );
    assert.equal(mcpRes.status, 200, mcpRes.body);
    await until("Outbound Slack chat.postMessage received", () =>
      slackPosted.some((b) => b.includes("reply-from-pion-mcp")) ? true : null,
    10_000);

    // 1a-ii (Opus R2 P1-C): Pure-card `chat_post` (no `text`, only `card`) persists `entries.card`
    // in SQLite, returns structured JSON with `thread`, and forwards Block Kit card to Slack;
    // `chat_state` returns structured JSON with `thread` so status-line gating executes.
    const cardPostRes = await httpCall(
      mcpPort,
      "POST",
      "/mcp",
      { "content-type": "application/json", authorization: `Bearer ${slackSessRow.token}` },
      JSON.stringify({
        jsonrpc: "2.0",
        id: 2,
        method: "tools/call",
        params: {
          name: "chat_post",
          arguments: {
            to: "C_B5/1700.100",
            card: { type: "options", options: [{ label: "ApproveCard" }] },
          },
        },
      }),
    );
    assert.equal(cardPostRes.status, 200, cardPostRes.body);
    const cardPostParsed = JSON.parse(JSON.parse(cardPostRes.body).result.content[0].text);
    assert.ok(cardPostParsed.thread > 0 && cardPostParsed.n > 0, `P1-C card-only chat_post must return structured thread/n, got: ${cardPostRes.body}`);
    await until("P1-C outbound Slack card-only post received", () =>
      slackPosted.some((b) => b.includes("ApproveCard")) ? true : null,
    10_000);
    {
      const roCard = new DatabaseSync(join(dataDir, "stillfail.db"), { open: true, readOnly: true });
      const cardRow = roCard.prepare("SELECT card FROM entries WHERE thread = ? AND n = ?").get(cardPostParsed.thread, cardPostParsed.n) as { card: string | null } | undefined;
      roCard.close();
      assert.ok(cardRow?.card && cardRow.card.includes("ApproveCard"), `P1-C card must be persisted in entries.card, got: ${JSON.stringify(cardRow)}`);
    }
    const stateRes = await httpCall(
      mcpPort,
      "POST",
      "/mcp",
      { "content-type": "application/json", authorization: `Bearer ${slackSessRow.token}` },
      JSON.stringify({
        jsonrpc: "2.0",
        id: 3,
        method: "tools/call",
        params: { name: "chat_state", arguments: { kind: "waiting", for: "checking", seconds: 30 } },
      }),
    );
    assert.equal(stateRes.status, 200, stateRes.body);
    const stateParsed = JSON.parse(JSON.parse(stateRes.body).result.content[0].text);
    assert.equal(stateParsed.ok, true);
    assert.equal(stateParsed.thread, cardPostParsed.thread);

    // 1b. Comma task.invite + task.put -> verify response {through: 1} & SQLite persistence!
    commaClientWs.send(JSON.stringify({
      id: "inv-1",
      type: "request",
      method: "task.invite",
      params: { task: "task-b5", start: { requester: "u-comma" } },
    }));
    await until("Comma task.invite response", () => commaFrames.find((f) => f.id === "inv-1" && f.type === "response") ?? null, 10_000);
    commaClientWs.send(JSON.stringify({
      id: "put-1",
      type: "request",
      method: "task.put",
      params: { task: "task-b5", through: 1, answered: 0, messages: [{ seq: 1, author: { kind: "person", id: "u-comma" }, text: "hello comma pion" }] },
    }));
    await until("Comma task.put committed with through=1", () =>
      commaFrames.find((f) => f.id === "put-1" && f.type === "response" && f.result?.through === 1) ?? null,
    10_000);

    launcher.kill("SIGTERM");
    await until("W17B-5 Scenario 1 launcher exit", () => launcher.exitCode !== null || launcher.signalCode !== null);

    const checkDb = new DatabaseSync(join(dataDir, "stillfail.db"), { readOnly: true });
    const msgRows = checkDb.prepare("SELECT kind, text FROM entries ORDER BY thread, n").all() as { kind: string; text: string | null }[];
    const delivCount = (checkDb.prepare("SELECT COUNT(*) AS c FROM deliveries").get() as { c: number }).c;
    checkDb.close();
    assert.ok(msgRows.some((r) => r.kind === "message" && (r.text ?? "").includes("hello pion hub")), "Slack inbound message persisted");
    assert.ok(msgRows.some((r) => r.kind === "edit" && (r.text ?? "").includes("hello pion hub edited")), "Slack edit persisted");
    assert.ok(msgRows.some((r) => r.kind === "message" && (r.text ?? "").includes("hello comma pion")), "Comma inbound message persisted");
    assert.ok(delivCount >= 2, `expected >= 2 deliveries rows, got ${delivCount}`);
  }

  // --- Scenario 2: Pure Pion cross-station connect.event + remote-connects.json + comma.read_file (zero Node!) ---
  {
    const dir = freshDir("w17b5-remote-connects");
    const appDir = join(dir, "app");
    const dataDir = join(dir, "data");
    installReleaseDir(appDir, pionBin, readerBin, runnerBin, false);
    mkdirSync(join(dataDir, "mesh"), { recursive: true });
    const idRes = spawnSync(pionBin, ["id", "--data", dataDir], { encoding: "utf8" });
    assert.equal(idRes.status, 0, idRes.stderr);
    const stationId = idRes.stdout.trim();

    const peerEp = await bindClientEp(mesh);
    const peerId = peerEp.id();

    // Seed an upload file inside a session workspace for comma.read_file
    const uploadDir = join(dir, "sess-ws", "uploads");
    mkdirSync(uploadDir, { recursive: true });
    const uploadPath = join(uploadDir, "shot.png");
    const uploadBytes = Buffer.from("PNG-W17B5-PAYLOAD");
    writeFileSync(uploadPath, uploadBytes);
    {
      const seed = Store.open(join(dataDir, "stillfail.db"), join(dataDir, "archive"));
      const now = Date.now();
      seed.db.prepare("INSERT INTO sessions (key, connect, scope, title, runtime, profile, workspace, token, created_at, last_active_at, cwd, ws) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)").run("s-rf", "chat", "s-rf", "RF", "claude", "default", join(dir, "sess-ws"), randomBytes(32).toString("hex"), now, now, join(dir, "sess-ws"), "ws-rem-b5");
      seed.db.prepare("INSERT INTO threads (id, surface, channel, thread_ts, title, created_at, home) VALUES (10, 'web', 'CHAT', '10.001', 'RFThread', ?, 'ws-rem-b5')").run(now);
      seed.db.prepare("INSERT INTO thread_sessions (thread, session, connect, joined_at) VALUES (10, 's-rf', 'chat', ?)").run(now);
      seed.db.prepare("INSERT INTO entries (thread, n, kind, ts, author_kind, author, text, attachments, at) VALUES (10, 1, 'message', '10.001', 'person', 'u1', 'see file', ?, ?)").run(JSON.stringify([{ name: "shot.png", path: uploadPath }]), now);
      seed.close();
    }

    writeFileSync(join(dataDir, "config.json"), JSON.stringify({ engine: "pion", connects: [] }));
    writeFileSync(
      join(dataDir, "mesh", "cloud.json"),
      JSON.stringify({
        workspace: "ws-rem-b5",
        workspace_name: "RemB5WS",
        station: stationId,
        name: "rem-b5-station",
        peers: [{ id: peerId, name: "peer-b5", relay: null }],
        relay_urls: [],
        grant_keys: grantKeys,
      }),
    );

    const udpPort = await pickFreeUdpPort();
    const launcher = spawn(launcherBin, ["run", "--app", appDir, "--data", dataDir, "--port", "0"], {
      env: { ...process.env, STILLFAIL_NO_DISCOVERY: "1", STILLFAIL_NO_DHT: "1", STILLFAIL_MESH_BIND_ADDR: `127.0.0.1:${udpPort}` },
      stdio: "ignore",
    });
    children.push(launcher);

    const pionPid = await until("Scenario 2 pure Pion pid", () => {
      const p = readHubPid(dataDir);
      return p > 0 && isAlive(p) && readProcCmdline(p).includes("stillfail-station-pion") ? p : null;
    }, 25_000);
    assert.match(readProcCmdline(pionPid), /stillfail-station-pion/);

    const described = {
      kind: "slack",
      workspace: "ws-rem-b5",
      mode: "multi-session",
      requireMention: false,
      bind: { runtime: "claude" },
      team: "T_REMB5",
    };
    const ev1 = await until("Scenario 2 connect.event message on pure Pion", async () => {
      try {
        return await peerRpc(peerEp, stationId, `127.0.0.1:${udpPort}`, "ws-rem-b5", {
          method: "connect.event",
          workspace: "ws-rem-b5",
          connect: { id: "slack-rem", origin: peerId },
          described,
          event: {
            type: "message",
            message: { channel: "C_REM", threadTs: "500.001", ts: "500.001", user: "U_REM", text: "remote-msg-on-pion", addressed: true },
          },
        });
      } catch { return null; }
    }, 15_000);
    assert.deepEqual(ev1.result, { ok: true });

    const ev2 = await peerRpc(peerEp, stationId, `127.0.0.1:${udpPort}`, "ws-rem-b5", {
      method: "connect.event",
      workspace: "ws-rem-b5",
      connect: { id: "slack-rem", origin: peerId },
      described,
      event: { type: "changed", channel: "C_REM", threadTs: "500.001", ts: "500.001", text: "remote-msg-edited-on-pion" },
    });
    assert.deepEqual(ev2.result, { ok: true });

    // Verify comma.read_file peer RPC returns exact base64 bytes of upload
    const rfRes = await peerRpc(peerEp, stationId, `127.0.0.1:${udpPort}`, "ws-rem-b5", {
      method: "comma.read_file",
      workspace: "ws-rem-b5",
      readFile: { thread: 10, seq: 1, file: "shot.png", offset: 0 },
    });
    assert.equal(rfRes.result.name, "shot.png");
    assert.equal(rfRes.result.size, uploadBytes.length);
    assert.equal(Buffer.from(rfRes.result.data, "base64").toString("utf8"), "PNG-W17B5-PAYLOAD");

    assert.equal(existsSync(join(dataDir, "remote-connects.json")), true, "Pion must persist remote-connects.json");

    launcher.kill("SIGTERM");
    await until("Scenario 2 launcher exit", () => launcher.exitCode !== null || launcher.signalCode !== null);

    const ro = new DatabaseSync(join(dataDir, "stillfail.db"), { readOnly: true });
    const rows = ro.prepare("SELECT kind, text FROM entries WHERE text LIKE ?").all("%remote-msg%") as { kind: string; text: string }[];
    ro.close();
    assert.ok(rows.some((r) => r.kind === "message" && r.text === "remote-msg-on-pion"));
    assert.ok(rows.some((r) => r.kind === "edit" && r.text === "remote-msg-edited-on-pion"));
  }

  // --- Scenario 3: Pure Pion native <data>/restore/ready.json cold restore (zero Node!) ---
  {
    const srcDir = freshDir("w17b5-rest-src");
    const srcDb = join(srcDir, "stillfail.db");
    const ws = "ws-b5-rest";
    const nowMs = Date.now();
    const peerEp = await bindClientEp(mesh);
    const peerId = peerEp.id();
    const remoteConnectId = `slack-b5@${peerId}`;
    const r13OpId = "op-b5-uuid-5678";

    const srcStore = Store.open(srcDb, join(srcDir, "archives"));
    srcStore.db.prepare("INSERT INTO sessions (key, connect, scope, title, runtime, profile, workspace, token, created_at, last_active_at, cwd, ws) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)").run("s:b5-rem", remoteConnectId, "s:b5-rem", "RestoredB5", "claude", "default", srcDir, randomBytes(32).toString("hex"), nowMs, nowMs, srcDir, ws);
    srcStore.db.prepare("INSERT INTO threads (id, surface, channel, thread_ts, title, created_at) VALUES (1, 'slack:T_B5', 'C_B5', '200.001', 'RestoredB5Thread', ?)").run(nowMs);
    srcStore.db.prepare("INSERT INTO thread_sessions (thread, session, connect, joined_at) VALUES (1, 's:b5-rem', ?, ?)").run(remoteConnectId, nowMs);
    srcStore.db.prepare("INSERT INTO entries (thread, n, kind, ts, author_kind, author, text, at) VALUES (1, 1, 'message', '200.001', 'person', 'U_B5', 'before-b5-restore', ?)").run(nowMs);
    srcStore.db.prepare("INSERT INTO turns (id, session_key, kind, started_at, ended_at, outcome, thread) VALUES (?, ?, 'turn', ?, ?, 'completed', 1)").run("b5-saved-turn", "s:b5-rem", nowMs - 1000, nowMs);
    srcStore.db.prepare("INSERT INTO proposal_outcomes (thread, n, status, project, resolved_by, resolved_at, info_note, info_refs, info_synced, info_op_id) VALUES (1, 1, 'accepted', 'ProjB5', 'alice@example.com', ?, 'note-b5', '[]', 0, ?)").run(nowMs, r13OpId);

    const originId = "b".repeat(64);
    const exp = new Exporter({ db: srcDb, replica: join(srcDir, "replica"), dataDir: srcDir, origin: originId, now: () => nowMs });
    exp.setPlaces({ home: ws, workspaces: [{ workspace: ws, name: "src-b5" }] });
    let passRes = exp.pass(nothingTold());
    while (passRes.more) passRes = exp.pass(nothingTold());
    const head = passRes.heads[ws];
    assert.ok(head, "expected Exporter head");
    const genPath = genDir(ownDir(join(srcDir, "replica")), ws, head.gen);
    const filesSrcDir = join(srcDir, "exported-files");
    mkdirSync(filesSrcDir, { recursive: true });
    for (const hash of Object.keys(head.files)) {
      const p = exp.sourceOf(hash);
      if (p) copyFileSync(p, join(filesSrcDir, hash));
    }
    exp.close();
    srcStore.close();

    const dir = freshDir("w17b5-rest-dst");
    const appDir = join(dir, "app");
    const dataDir = join(dir, "data");
    installReleaseDir(appDir, pionBin, readerBin, runnerBin, false);
    mkdirSync(join(dataDir, "mesh"), { recursive: true });
    const idRes = spawnSync(pionBin, ["id", "--data", dataDir], { encoding: "utf8" });
    assert.equal(idRes.status, 0, idRes.stderr);
    const stationId = idRes.stdout.trim();

    const copyDir = join(dataDir, "restore", "copy");
    mkdirSync(copyDir, { recursive: true });
    cpSync(genPath, join(copyDir, head.gen), { recursive: true });
    cpSync(filesSrcDir, join(copyDir, "files"), { recursive: true });
    writeFileSync(join(dataDir, "restore", "ready.json"), JSON.stringify({ origin: originId, workspace: ws, gen: head.gen, name: "src-b5", from: peerId }));
    writeFileSync(join(dataDir, "config.json"), JSON.stringify({ engine: "pion", connects: [] }));
    writeFileSync(
      join(dataDir, "mesh", "cloud.json"),
      JSON.stringify({
        workspace: ws,
        workspace_name: "B5RestWS",
        station: stationId,
        name: "b5-rest-station",
        peers: [{ id: peerId, name: "peer-b5", relay: null }],
        relay_urls: [],
        grant_keys: grantKeys,
      }),
    );

    const udpPort = await pickFreeUdpPort();
    const launcher = spawn(launcherBin, ["run", "--app", appDir, "--data", dataDir, "--port", "0"], {
      env: { ...process.env, STILLFAIL_NO_DISCOVERY: "1", STILLFAIL_NO_DHT: "1", STILLFAIL_MESH_BIND_ADDR: `127.0.0.1:${udpPort}` },
      stdio: "ignore",
    });
    children.push(launcher);

    const pionPid = await until("Scenario 3 pure Pion pid after native restore", async () => {
      const p = readHubPid(dataDir);
      const port = readPorts(dataDir).admin ?? 0;
      if (p > 0 && isAlive(p) && port > 0 && readProcCmdline(p).includes("stillfail-station-pion")) {
        try {
          if ((await httpCall(port, "GET", "/healthz")).status === 200) return p;
        } catch {}
      }
      return null;
    }, 25_000);
    assert.match(readProcCmdline(pionPid), /stillfail-station-pion/);

    await until("Scenario 3 native Pion replica restore completed", () => existsSync(join(dataDir, "replica", "restored.json")) ? true : null, 15_000);
    const restoredOut = JSON.parse(readFileSync(join(dataDir, "replica", "restored.json"), "utf8"));
    assert.equal(restoredOut.error, null, `expected restored.json error === null, got: ${JSON.stringify(restoredOut)}`);
    assert.equal(existsSync(join(dataDir, "restore")), false, "native Pion restore must clean restore/");

    launcher.kill("SIGTERM");
    await until("Scenario 3 launcher exit", () => launcher.exitCode !== null || launcher.signalCode !== null);

    const verifyStore = Store.open(join(dataDir, "stillfail.db"), join(dataDir, "archive"));
    const sessRow = verifyStore.getSession("s:b5-rem");
    assert.ok(sessRow !== null && sessRow.connect === remoteConnectId, "native restore recovered s:b5-rem");
    const turnRow = verifyStore.db.prepare("SELECT outcome FROM turns WHERE id = ?").get("b5-saved-turn") as { outcome: string } | undefined;
    assert.equal(turnRow?.outcome, "completed");
    const outcome = verifyStore.getUnsyncedAcceptOutcome(1, 1);
    verifyStore.close();
    assert.ok(outcome !== null && outcome.opId === r13OpId && outcome.project === "ProjB5");

    // Schema version parity guard
    const pionSchemaSrc = readFileSync(join(root, "pion", "station-main", "packages", "station_store", "src", "schema.pion"), "utf8");
    const m = pionSchemaSrc.match(/pub let SCHEMA_VERSION\s*:\s*Int\s*=\s*(\d+)/);
    assert.ok(m, "expected SCHEMA_VERSION constant");
    assert.equal(Number(m[1]), SCHEMA_VERSION);
  }

  // --- Scenario 4 (Opus R2 P0-A + P0-B): Runtime connect.event gate fail-closed + TS answerCall wire parity ---
  {
    // (a) P0-B: Pion `build_connect_call_post_request` wire shape vs real TS `answerCall`
    const { answerCall } = await import("../src/connects/remote.ts");
    let capturedPost: any = null;
    const fakeSurface: any = {
      post: async (thread: any, message: string, files: any[], card: any) => {
        capturedPost = { thread, message, files, card };
        return "ts-posted-1";
      },
    };
    const handler = answerCall((known, ws) => (known.id === "slack-1" && known.origin === "st-origin" && ws === "ws-b5" ? fakeSurface : undefined), join(freshDir("answer-call-up"), "up"));
    const pionWirePayload = {
      method: "connect.call",
      workspace: "ws-b5",
      connect: { id: "slack-1", origin: "st-origin" },
      op: "post",
      args: [
        { channel: "C_REM", threadTs: "100.1", replyTo: "om_1" },
        "hello from pion",
        [],
        { type: "options", options: [{ label: "Ship" }] },
      ],
    };
    const ans = await handler("peer-pion", pionWirePayload, "ws-b5");
    assert.deepEqual(ans, { result: "ts-posted-1" });
    assert.deepEqual(capturedPost, {
      thread: { channel: "C_REM", threadTs: "100.1", replyTo: "om_1" },
      message: "hello from pion",
      files: [],
      card: { type: "options", options: [{ label: "Ship" }] },
    });

    // (b) Wave 17C-1: Clean Pion whole station WITHOUT any test env flag accepts
    // runtime `connect.event` natively and persists the remote connect + session + entry.
    const dir = freshDir("w17c1-native-connect-event");
    const appDir = join(dir, "app");
    const dataDir = join(dir, "data");
    installReleaseDir(appDir, pionBin, readerBin, runnerBin, false);
    mkdirSync(join(dataDir, "mesh"), { recursive: true });
    const idRes = spawnSync(pionBin, ["id", "--data", dataDir], { encoding: "utf8" });
    assert.equal(idRes.status, 0, idRes.stderr);
    const stationId = idRes.stdout.trim();
    const peerEp = await bindClientEp(mesh);
    const peerId = peerEp.id();
    const ws = "ws-c1-native";
    writeFileSync(join(dataDir, "config.json"), JSON.stringify({ engine: "pion", connects: [] }));
    writeFileSync(
      join(dataDir, "mesh", "cloud.json"),
      JSON.stringify({
        workspace: ws,
        workspace_name: "C1NativeWS",
        station: stationId,
        name: "c1-native-station",
        peers: [{ id: peerId, name: "peer-sender", relay: null }],
        relay_urls: [],
        grant_keys: grantKeys,
      }),
    );
    const udpPort = await pickFreeUdpPort();
    const launcher = spawn(launcherBin, ["run", "--app", appDir, "--data", dataDir, "--port", "0"], {
      env: { ...process.env, STILLFAIL_NO_DISCOVERY: "1", STILLFAIL_NO_DHT: "1", STILLFAIL_MESH_BIND_ADDR: `127.0.0.1:${udpPort}` },
      stdio: "ignore",
    });
    children.push(launcher);
    await until("W17C-1 native station ready", async () => {
      const p = readHubPid(dataDir);
      const port = readPorts(dataDir).admin ?? 0;
      if (p > 0 && isAlive(p) && port > 0 && readProcCmdline(p).includes("stillfail-station-pion")) {
        try {
          if ((await httpCall(port, "GET", "/healthz")).status === 200) return p;
        } catch {}
      }
      return null;
    }, 20_000);
    const nativeResp = await until("W17C-1 connect.event accepted natively", async () => {
      try {
        return await peerRpc(peerEp, stationId, `127.0.0.1:${udpPort}`, ws, {
          method: "connect.event",
          workspace: ws,
          connect: { id: "slack-peer", origin: peerId },
          described: { kind: "slack", workspace: ws, mode: "per-thread", requireMention: true, bind: { runtime: "claude" } },
          event: { type: "message", message: { channel: "C1", threadTs: "1.1", ts: "1.1", user: "U1", text: "native connect event ok", addressed: true } },
        });
      } catch {
        return null;
      }
    }, 15_000);
    assert.deepEqual(nativeResp.result, { ok: true }, `expected native connect.event acceptance, got: ${JSON.stringify(nativeResp)}`);
    assert.equal(existsSync(join(dataDir, "remote-connects.json")), true, "native connect.event must persist remote-connects.json");
    launcher.kill("SIGTERM");
    await until("W17C-1 native launcher exit", () => launcher.exitCode !== null || launcher.signalCode !== null);
    const checkDb = new DatabaseSync(join(dataDir, "stillfail.db"), { open: true, readOnly: true });
    const sessCnt = (checkDb.prepare("SELECT COUNT(*) AS n FROM sessions").get() as { n: number }).n;
    const entryCnt = (checkDb.prepare("SELECT COUNT(*) AS n FROM entries").get() as { n: number }).n;
    checkDb.close();
    assert.ok(sessCnt >= 1, "native connect.event must create session");
    assert.ok(entryCnt >= 1, "native connect.event must insert entry");
  }
});

test("W17C-1: Live stillfail-runner spawning & full agent turn loop (Web/Hub MCP chat_post+chat_state, native Slack connect without env flag, graceful SIGUSR2 handover)", async () => {
  const mesh = resolveMeshAddon();
  const { grantKeys, signMemberJwt } = makeGrantKeysAndSigner();
  const pionBin = resolvePionBinary();
  const readerBin = resolveNativeTool("STILLFAIL_READER", "reader", "stillfail-reader");
  const runnerBin = resolveNativeTool("STILLFAIL_RUNNER", "runner", "stillfail-runner");

  // Helper: create a real executable mock `claude` CLI on PATH that speaks Claude `stream-json`,
  // parses real `--mcp-config` & `--append-system-prompt` from `process.argv` (expanding `${STILLFAIL_MCP_TOKEN}`),
  // verifies `<message ...>` envelope framing, and calls the station's real `/mcp` endpoint!
  function writeMockClaude(binDir: string, mode: "reply" | "hold", releaseFlagPath = ""): string {
    mkdirSync(binDir, { recursive: true });
    const scriptPath = join(binDir, "claude");
    const commonHeader = `#!${process.execPath}
const readline = require("node:readline");
const http = require("node:http");
const fs = require("node:fs");

function argAfter(flag) {
  const idx = process.argv.indexOf(flag);
  return idx >= 0 && idx + 1 < process.argv.length ? process.argv[idx + 1] : "";
}

const sysPrompt = argAfter("--append-system-prompt");
const mcpCfgRaw = argAfter("--mcp-config");
let mcpUrl = "";
let mcpAuth = "";
if (mcpCfgRaw) {
  try {
    const cfg = JSON.parse(mcpCfgRaw);
    const srv = cfg.mcpServers && cfg.mcpServers.stillfail;
    if (srv) {
      mcpUrl = srv.url || "";
      const rawAuth = (srv.headers && srv.headers.Authorization) || "";
      mcpAuth = rawAuth.replace(/\\$\\{STILLFAIL_MCP_TOKEN\\}/g, process.env.STILLFAIL_MCP_TOKEN || "");
    }
  } catch {}
}

function mcpCall(name, args) {
  return new Promise((resolve, reject) => {
    const u = new URL(mcpUrl);
    const payload = JSON.stringify({
      jsonrpc: "2.0",
      id: "mcp-" + Date.now() + "-" + Math.random(),
      method: "tools/call",
      params: { name, arguments: args },
    });
    const req = http.request(
      {
        hostname: u.hostname,
        port: Number(u.port),
        path: u.pathname,
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Authorization": mcpAuth,
          "Content-Length": Buffer.byteLength(payload),
        },
      },
      (res) => {
        const chunks = [];
        res.on("data", (c) => chunks.push(c));
        res.on("end", () => resolve({ status: res.statusCode, body: Buffer.concat(chunks).toString("utf8") }));
      },
    );
    req.on("error", reject);
    req.write(payload);
    req.end();
  });
}

function extractUserText(msg) {
  const c = msg && msg.message && msg.message.content;
  if (Array.isArray(c) && c.length > 0 && typeof c[0].text === "string") return c[0].text;
  return "";
}
`;
    const body = mode === "reply"
      ? `${commonHeader}
process.stdout.write(JSON.stringify({ type: "system", subtype: "init", session_id: "mock-claude-sid-1" }) + "\\n");
const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
rl.on("line", async (line) => {
  if (!line.trim()) return;
  let msg;
  try { msg = JSON.parse(line); } catch { return; }
  if (msg.type === "user") {
    const txt = extractUserText(msg);
    const okArgs = sysPrompt.includes("You work on this machine") && mcpUrl.startsWith("http://127.0.0.1:") && mcpAuth.startsWith("Bearer ");
    const okEnv = txt.includes("<message ") && txt.includes("</message>");
    if (okArgs && okEnv) {
      await mcpCall("chat_post", { text: "hello from live pion runner" });
      await mcpCall("chat_state", { kind: "all_done", done: "replied via live runner" });
    } else {
      await mcpCall("chat_post", { text: "BAD_CONTRACT okArgs=" + okArgs + " okEnv=" + okEnv });
      await mcpCall("chat_state", { kind: "all_done", done: "contract check failed" });
    }
    process.stdout.write(JSON.stringify({
      type: "result",
      is_error: false,
      session_id: "mock-claude-sid-1",
      usage: { input_tokens: 15, output_tokens: 25 },
    }) + "\\n");
  }
});
`
      : `${commonHeader}
const releaseFlag = ${JSON.stringify(releaseFlagPath)};
let turnNum = 0;
process.stdout.write(JSON.stringify({ type: "system", subtype: "init", session_id: "mock-claude-ho-1" }) + "\\n");
const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
rl.on("line", async (line) => {
  if (!line.trim()) return;
  let msg;
  try { msg = JSON.parse(line); } catch { return; }
  if (msg.type === "user") {
    turnNum += 1;
    if (turnNum === 1) {
      fs.writeFileSync(releaseFlag + ".started", "1");
      while (!fs.existsSync(releaseFlag)) {
        await new Promise((r) => setTimeout(r, 80));
      }
      await mcpCall("chat_post", { text: "turn1 finished on successor" });
      await mcpCall("chat_state", { kind: "all_done", done: "turn1 done after SIGUSR2" });
      process.stdout.write(JSON.stringify({
        type: "result",
        is_error: false,
        session_id: "mock-claude-ho-1",
        usage: { input_tokens: 10, output_tokens: 12 },
      }) + "\\n");
    } else {
      await mcpCall("chat_post", { text: "turn2 reused runner pid=" + process.pid });
      await mcpCall("chat_state", { kind: "all_done", done: "turn2 done on reused runner" });
      process.stdout.write(JSON.stringify({
        type: "result",
        is_error: false,
        session_id: "mock-claude-ho-1",
        usage: { input_tokens: 8, output_tokens: 9 },
      }) + "\\n");
    }
  }
});
setInterval(() => {}, 60000);
`;
    writeFileSync(scriptPath, body, { mode: 0o755 });
    chmodSync(scriptPath, 0o755);
    return scriptPath;
  }

  // -------------------------------------------------------------------------
  // Scenario 1: Web/Hub session -> live stillfail-runner -> /mcp chat_post + chat_state -> SQLite all_done
  // -------------------------------------------------------------------------
  {
    const dir = freshDir("c1-w");
    const appDir = join(dir, "app");
    const dataDir = join(dir, "data");
    const mockBinDir = join(dir, "mock-bin");
    writeMockClaude(mockBinDir, "reply");
    installReleaseDir(appDir, pionBin, readerBin, runnerBin, false);
    mkdirSync(join(dataDir, "mesh"), { recursive: true });
    const idRes = spawnSync(pionBin, ["id", "--data", dataDir], { encoding: "utf8" });
    assert.equal(idRes.status, 0, idRes.stderr);
    const stationId = idRes.stdout.trim();
    const ws = "ws-c1-web";
    writeFileSync(join(dataDir, "config.json"), JSON.stringify({ engine: "pion", connects: [] }));
    writeFileSync(
      join(dataDir, "mesh", "cloud.json"),
      JSON.stringify({
        workspace: ws,
        workspace_name: "C1WebWS",
        station: stationId,
        name: "c1-web-station",
        peers: [],
        relay_urls: [],
        grant_keys: grantKeys,
      }),
    );

    const udpPort = await pickFreeUdpPort();
    const launcher = spawn(launcherBin, ["run", "--app", appDir, "--data", dataDir, "--port", "0"], {
      env: {
        ...process.env,
        PATH: `${mockBinDir}:${process.env.PATH ?? ""}`,
        STILLFAIL_RUNNER: runnerBin,
        STILLFAIL_NO_DISCOVERY: "1",
        STILLFAIL_NO_DHT: "1",
        STILLFAIL_MESH_BIND_ADDR: `127.0.0.1:${udpPort}`,
      },
      stdio: "ignore",
    });
    children.push(launcher);
    try {
      await until("W17C-1 S1 station ready", async () => {
        const p = readHubPid(dataDir);
        const port = readPorts(dataDir).admin ?? 0;
        if (p > 0 && isAlive(p) && port > 0 && readProcCmdline(p).includes("stillfail-station-pion")) {
          try {
            if ((await httpCall(port, "GET", "/healthz")).status === 200) return p;
          } catch {}
        }
        return null;
      }, 20_000);

      const clientEp = await bindClientEp(mesh);
      const jwt = signMemberJwt({ ws, device: clientEp.id(), sub: "u-c1", email: "c1@example.com", name: "C1", role: "owner" });
      const { conn } = await until("W17C-1 S1 admin connect", () => openAdminConn(clientEp, stationId, `127.0.0.1:${udpPort}`, jwt));
      const createRes = await adminRequest(
        conn,
        "POST",
        "/sessions",
        [["content-type", "application/json"]],
        JSON.stringify({ runtime: "claude", profile: "p1", title: "W17C-1 Web Live Turn" }),
      );
      assert.equal(createRes.status, 200, `POST /sessions failed: ${createRes.body.toString("utf8")}`);
      const created = JSON.parse(createRes.body.toString("utf8"));
      const sessionKey = created.key as string;
      const threadId = created.thread as number;
      assert.ok(sessionKey && threadId > 0, `expected key & thread, got ${JSON.stringify(created)}`);

      const msgRes = await adminRequest(
        conn,
        "POST",
        `/threads/${threadId}/messages`,
        [["content-type", "application/json"]],
        JSON.stringify({ text: "ping live runner" }),
      );
      assert.equal(msgRes.status, 200, `POST /threads/:id/messages failed: ${msgRes.body.toString("utf8")}`);
      conn.close(0, "done");

      // Wait for real stillfail-runner + mock claude to call /mcp chat_post + chat_state and complete the turn!
      await until("W17C-1 S1 live reply & all_done turn in SQLite", () => {
        try {
          const db = new DatabaseSync(join(dataDir, "stillfail.db"), { open: true, readOnly: true });
          try {
            const entry = db.prepare("SELECT text FROM entries WHERE thread = ? AND author_kind = 'agent' AND text = 'hello from live pion runner'").get(threadId) as { text: string } | undefined;
            const turn = db.prepare("SELECT outcome, declared FROM turns WHERE session_key = ? ORDER BY started_at DESC LIMIT 1").get(sessionKey) as { outcome: string | null; declared: string | null } | undefined;
            const sess = db.prepare("SELECT runtime_session_id, running FROM sessions WHERE key = ?").get(sessionKey) as { runtime_session_id: string | null; running: number } | undefined;
            if (entry && turn?.outcome === "completed" && turn?.declared === "all_done" && sess?.running === 0 && sess?.runtime_session_id === "mock-claude-sid-1") {
              return true;
            }
          } finally {
            db.close();
          }
        } catch {}
        return null;
      }, 25_000);
    } finally {
      launcher.kill("SIGTERM");
      await until("W17C-1 S1 launcher exit", () => launcher.exitCode !== null || launcher.signalCode !== null, 15_000).catch(() => {});
    }
  }

  // -------------------------------------------------------------------------
  // Scenario 2: External Connect (Slack) WITHOUT STILLFAIL_PION_NATIVE_CONNECTS_TEST
  // -> stays on Pion -> spawns live runner -> agent calls /mcp chat_post -> delivered to mock Slack!
  // -------------------------------------------------------------------------
  {
    const slackPosts: any[] = [];
    let slackClientWs: any = null;
    const slackSrv = createHttpServer((req, res) => {
      const chunks: Buffer[] = [];
      req.on("data", (c) => chunks.push(c));
      req.on("end", () => {
        const bodyStr = Buffer.concat(chunks).toString("utf8");
        const url = req.url ?? "";
        res.setHeader("Content-Type", "application/json");
        if (url.includes("apps.connections.open")) {
          const p = (slackSrv.address() as AddressInfo).port;
          res.end(JSON.stringify({ ok: true, url: `ws://127.0.0.1:${p}/slack-ws` }));
        } else if (url.includes("auth.test")) {
          res.end(JSON.stringify({ ok: true, user_id: "UBOTC1", bot_id: "BBOTC1", user: "c1bot", team_id: "TC1", team: "C1Team" }));
        } else if (url.includes("chat.postMessage")) {
          slackPosts.push(bodyStr);
          res.end(JSON.stringify({ ok: true, ts: "1700000100.000200" }));
        } else {
          res.end(JSON.stringify({ ok: true }));
        }
      });
    });
    servers.push(slackSrv);
    const slackWss = new WebSocketServer({ server: slackSrv, path: "/slack-ws" });
    servers.push(slackWss);
    const slackAckedC1: string[] = [];
    slackWss.on("connection", (ws) => {
      slackClientWs = ws;
      ws.on("message", (d) => {
        try {
          const m = JSON.parse(String(d));
          if (typeof m.envelope_id === "string") slackAckedC1.push(m.envelope_id);
        } catch {}
      });
      ws.send(JSON.stringify({ type: "hello", num_connections: 1 }));
    });
    await new Promise<void>((resolve) => slackSrv.listen(0, "127.0.0.1", () => resolve()));
    const slackPort = (slackSrv.address() as AddressInfo).port;

    const dir = freshDir("c1-sl");
    const appDir = join(dir, "app");
    const dataDir = join(dir, "data");
    const mockBinDir = join(dir, "mock-bin");
    writeMockClaude(mockBinDir, "reply");
    // withRealNodeMain = false: main.js exits 99 -> proves zero Node fallback without any env flag!
    installReleaseDir(appDir, pionBin, readerBin, runnerBin, false);
    mkdirSync(join(dataDir, "mesh"), { recursive: true });
    const idRes = spawnSync(pionBin, ["id", "--data", dataDir], { encoding: "utf8" });
    assert.equal(idRes.status, 0, idRes.stderr);
    const stationId = idRes.stdout.trim();
    const ws = "ws-c1-slack";
    writeFileSync(
      join(dataDir, "config.json"),
      JSON.stringify({
        engine: "pion",
        connects: [
          {
            id: "slack-c1",
            bind: { runtime: "claude" },
            slack: { appToken: "xapp-1-c1", botToken: "xoxb-c1", baseUrl: `http://127.0.0.1:${slackPort}` },
          },
        ],
      }),
    );
    writeFileSync(
      join(dataDir, "mesh", "cloud.json"),
      JSON.stringify({
        workspace: ws,
        workspace_name: "C1SlackWS",
        station: stationId,
        name: "c1-slack-station",
        peers: [],
        relay_urls: [],
        grant_keys: grantKeys,
      }),
    );

    const udpPort = await pickFreeUdpPort();
    const envCopy = { ...process.env };
    delete envCopy.STILLFAIL_PION_NATIVE_CONNECTS_TEST;
    const launcher = spawn(launcherBin, ["run", "--app", appDir, "--data", dataDir, "--port", "0"], {
      env: {
        ...envCopy,
        PATH: `${mockBinDir}:${process.env.PATH ?? ""}`,
        STILLFAIL_RUNNER: runnerBin,
        STILLFAIL_NO_DISCOVERY: "1",
        STILLFAIL_NO_DHT: "1",
        STILLFAIL_MESH_BIND_ADDR: `127.0.0.1:${udpPort}`,
      },
      stdio: "ignore",
    });
    children.push(launcher);
    try {
      const pionPid = await until("W17C-1 S2 pure Pion pid", () => {
        const p = readHubPid(dataDir);
        return p > 0 && isAlive(p) && readProcCmdline(p).includes("stillfail-station-pion") ? p : null;
      }, 25_000);
      assert.match(readProcCmdline(pionPid), /stillfail-station-pion/);
      await until("W17C-1 S2 Slack WS connected", () => (slackClientWs ? true : null), 15_000);

      slackClientWs.send(JSON.stringify({
        type: "events_api",
        envelope_id: "env-c1-1",
        payload: {
          event_id: "EvC1_1",
          event: {
            type: "app_mention",
            channel: "C_C1",
            ts: "1700000100.000100",
            thread_ts: "1700000100.000100",
            user: "UALICE",
            text: "<@UBOTC1> run live runner on slack",
          },
        },
      }));
      await until("W17C-1 S2 Slack envelope env-c1-1 ACKed", () => (slackAckedC1.includes("env-c1-1") ? true : null), 10_000);

      // Verify mock claude ran under stillfail-runner, called /mcp chat_post, and Pion posted back to Slack!
      const posted = await until(
        "W17C-1 S2 outbound Slack post from live runner",
        () => slackPosts.find((p) => decodeURIComponent(String(p)).includes("hello from live pion runner")) ?? null,
        20_000,
      );
      assert.ok(decodeURIComponent(String(posted)).includes("channel=C_C1"), `expected channel=C_C1 in Slack post: ${posted}`);
    } finally {
      launcher.kill("SIGTERM");
      await until("W17C-1 S2 launcher exit", () => launcher.exitCode !== null || launcher.signalCode !== null, 15_000).catch(() => {});
    }
  }

  // -------------------------------------------------------------------------
  // Scenario 3: Graceful SIGUSR2 handover -> live stillfail-runner stays alive,
  // in-flight turn completes on successor via /mcp, AND second prompt reuses SAME runner PID!
  // -------------------------------------------------------------------------
  {
    const dir = freshDir("c1-ho");
    const appDir = join(dir, "app");
    const dataDir = join(dir, "data");
    const mockBinDir = join(dir, "mock-bin-ho");
    const releaseFlag = join(dir, "release-turn1.flag");
    writeMockClaude(mockBinDir, "hold", releaseFlag);
    installReleaseDir(appDir, pionBin, readerBin, runnerBin, false);
    mkdirSync(join(dataDir, "mesh"), { recursive: true });
    const idRes = spawnSync(pionBin, ["id", "--data", dataDir], { encoding: "utf8" });
    assert.equal(idRes.status, 0, idRes.stderr);
    const stationId = idRes.stdout.trim();
    const ws = "ws-c1-ho";
    writeFileSync(join(dataDir, "config.json"), JSON.stringify({ engine: "pion", connects: [] }));
    writeFileSync(
      join(dataDir, "mesh", "cloud.json"),
      JSON.stringify({
        workspace: ws,
        workspace_name: "C1HandoverWS",
        station: stationId,
        name: "c1-ho-station",
        peers: [],
        relay_urls: [],
        grant_keys: grantKeys,
      }),
    );

    const udpPort = await pickFreeUdpPort();
    const launcher = spawn(launcherBin, ["run", "--app", appDir, "--data", dataDir, "--port", "0"], {
      env: {
        ...process.env,
        PATH: `${mockBinDir}:${process.env.PATH ?? ""}`,
        STILLFAIL_RUNNER: runnerBin,
        STILLFAIL_NO_DISCOVERY: "1",
        STILLFAIL_NO_DHT: "1",
        STILLFAIL_MESH_BIND_ADDR: `127.0.0.1:${udpPort}`,
      },
      stdio: "ignore",
    });
    children.push(launcher);
    let liveRunnerPid = 0;
    let liveRunnerPgid = 0;
    try {
      const pionPid1 = await until("W17C-1 S3 initial Pion pid", async () => {
        const p = readHubPid(dataDir);
        const port = readPorts(dataDir).admin ?? 0;
        if (p > 0 && isAlive(p) && port > 0 && readProcCmdline(p).includes("stillfail-station-pion")) {
          try {
            if ((await httpCall(port, "GET", "/healthz")).status === 200) return p;
          } catch {}
        }
        return null;
      }, 20_000);

      const clientEp = await bindClientEp(mesh);
      const jwt = signMemberJwt({ ws, device: clientEp.id(), sub: "u-ho", email: "ho@example.com", name: "HO", role: "owner" });
      const { conn } = await until("W17C-1 S3 admin connect", () => openAdminConn(clientEp, stationId, `127.0.0.1:${udpPort}`, jwt));
      const createRes = await adminRequest(
        conn,
        "POST",
        "/sessions",
        [["content-type", "application/json"]],
        JSON.stringify({ runtime: "claude", profile: "p1", title: "W17C-1 Handover Hold" }),
      );
      assert.equal(createRes.status, 200);
      const created = JSON.parse(createRes.body.toString("utf8"));
      const sessionKey = created.key as string;
      const threadId = created.thread as number;
      const msgRes = await adminRequest(
        conn,
        "POST",
        `/threads/${threadId}/messages`,
        [["content-type", "application/json"]],
        JSON.stringify({ text: "hold open across SIGUSR2" }),
      );
      assert.equal(msgRes.status, 200);
      conn.close(0, "done");

      // Wait for real stillfail-runner to spawn and write its info file
      const runnersDir = join(dataDir, "run", "runners");
      const runnerInfo = await until("W17C-1 S3 live runner info file", () => {
        if (!existsSync(runnersDir)) return null;
        const files = readdirSync(runnersDir).filter((f) => f.endsWith(".json"));
        for (const f of files) {
          try {
            const info = JSON.parse(readFileSync(join(runnersDir, f), "utf8"));
            if (info.runner > 0 && isAlive(info.runner)) return info;
          } catch {}
        }
        return null;
      }, 20_000);
      liveRunnerPid = runnerInfo.runner;
      liveRunnerPgid = runnerInfo.pgid;
      extraPids.push(liveRunnerPid);
      if (liveRunnerPgid > 1) extraPids.push(liveRunnerPgid);

      // Wait until Turn 1 prompt is actually delivered and in-flight before triggering SIGUSR2 handover!
      await until("W17C-1 S3 turn1 prompt delivered", () => (existsSync(releaseFlag + ".started") ? true : null), 15_000);

      // Trigger graceful SIGUSR2 handover on launcher!
      launcher.kill("SIGUSR2");
      const pionPid2 = await until("W17C-1 S3 successor Pion pid after SIGUSR2", async () => {
        const p = readHubPid(dataDir);
        const port = readPorts(dataDir).admin ?? 0;
        if (p > 0 && p !== pionPid1 && isAlive(p) && port > 0 && readProcCmdline(p).includes("stillfail-station-pion")) {
          try {
            if ((await httpCall(port, "GET", "/healthz")).status === 200) return p;
          } catch {}
        }
        return null;
      }, 25_000);
      assert.notEqual(pionPid2, pionPid1);
      assert.equal(isAlive(liveRunnerPid), true, `live runner PID ${liveRunnerPid} MUST survive SIGUSR2 handover!`);

      // Release Turn 1 on the successor -> must complete via /mcp chat_post + chat_state(all_done) & SQLite running=0!
      writeFileSync(releaseFlag, "go");
      await until("W17C-1 S3 turn1 completed on successor", () => {
        try {
          const db = new DatabaseSync(join(dataDir, "stillfail.db"), { open: true, readOnly: true });
          try {
            const entry = db.prepare("SELECT text FROM entries WHERE thread = ? AND author_kind = 'agent' AND text = 'turn1 finished on successor'").get(threadId) as { text: string } | undefined;
            const turn = db.prepare("SELECT outcome, declared, ended_at FROM turns WHERE session_key = ? ORDER BY started_at DESC LIMIT 1").get(sessionKey) as { outcome: string | null; declared: string | null; ended_at: number | null } | undefined;
            const sess = db.prepare("SELECT running FROM sessions WHERE key = ?").get(sessionKey) as { running: number } | undefined;
            if (entry && turn?.outcome === "completed" && turn?.declared === "all_done" && turn?.ended_at !== null && sess?.running === 0) {
              return true;
            }
          } finally {
            db.close();
          }
        } catch {}
        return null;
      }, 25_000);

      // Send a SECOND prompt after SIGUSR2 -> must reuse the EXACT SAME live runner PID!
      const { conn: conn2 } = await until("W17C-1 S3 admin reconnect after SIGUSR2", () => openAdminConn(clientEp, stationId, `127.0.0.1:${udpPort}`, jwt));
      const msgRes2 = await adminRequest(
        conn2,
        "POST",
        `/threads/${threadId}/messages`,
        [["content-type", "application/json"]],
        JSON.stringify({ text: "second prompt after SIGUSR2" }),
      );
      assert.equal(msgRes2.status, 200);
      conn2.close(0, "done2");

      await until("W17C-1 S3 turn2 completed on reused runner", () => {
        try {
          const db = new DatabaseSync(join(dataDir, "stillfail.db"), { open: true, readOnly: true });
          try {
            const entry = db.prepare("SELECT text FROM entries WHERE thread = ? AND author_kind = 'agent' AND text LIKE 'turn2 reused runner%'").get(threadId) as { text: string } | undefined;
            const sess = db.prepare("SELECT running FROM sessions WHERE key = ?").get(sessionKey) as { running: number } | undefined;
            if (entry && sess?.running === 0) return true;
          } finally {
            db.close();
          }
        } catch {}
        return null;
      }, 25_000);
      assert.equal(isAlive(liveRunnerPid), true, "adopted live runner PID must STILL be alive after turn2 reuse");
      const runnerFilesAfter = readdirSync(runnersDir).filter((f) => f.endsWith(".json"));
      assert.equal(runnerFilesAfter.length, 1, `must not spawn a second colliding runner after SIGUSR2: ${runnerFilesAfter.join(",")}`);
    } finally {
      launcher.kill("SIGTERM");
      await until("W17C-1 S3 launcher exit", () => launcher.exitCode !== null || launcher.signalCode !== null, 15_000).catch(() => {});
    }
    // P1-3: Assert SIGTERM cleanly terminated the adopted live runner with ZERO orphan processes!
    if (liveRunnerPid > 0) {
      await until("W17C-1 S3 zero orphan runner after SIGTERM", () => (!isAlive(liveRunnerPid) ? true : null), 10_000);
      assert.equal(isAlive(liveRunnerPid), false, `live runner PID ${liveRunnerPid} leaked as orphan after SIGTERM!`);
    }
  }
});

test("W17C-1 R2 (P0-6): Native --internal-replica-restore safety matrix (6c-6j: locked DB, RLIMIT_FSIZE rollback, user_version=99, concurrent writer thread 73, 4-table turns, orphan/0-byte WAL, v13 column repair, v12->v13 cold restore)", async () => {
  const pionBin = resolvePionBinary();

  const srcDir = freshDir("r2-rest-src");
  const srcDb = join(srcDir, "stillfail.db");
  const ws = "ws-r2-rest";
  const nowMs = Date.now();
  const originId = "c".repeat(64);
  const remoteConnectId = "slack-r2@peer-r2";
  const r13OpId = "99999999-8888-4777-8666-555555555555";

  const srcStore = Store.open(srcDb, join(srcDir, "archives"));
  srcStore.db.prepare("INSERT INTO sessions (key, connect, scope, title, runtime, profile, workspace, token, created_at, last_active_at, cwd, ws) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)").run("s:r2-rem", remoteConnectId, "s:r2-rem", "RestoredR2", "claude", "default", srcDir, randomBytes(32).toString("hex"), nowMs, nowMs, srcDir, ws);
  srcStore.db.prepare("INSERT INTO threads (id, surface, channel, thread_ts, title, created_at) VALUES (1, 'slack:TR2', 'C_R2', '200.001', 'R2 Restore Thread', ?)").run(nowMs);
  srcStore.db.prepare("INSERT INTO thread_sessions (thread, session, connect, joined_at) VALUES (1, 's:r2-rem', ?, ?)").run(remoteConnectId, nowMs);
  srcStore.db.prepare("INSERT INTO entries (thread, n, kind, ts, author_kind, author, text, at) VALUES (1, 1, 'message', '200.001', 'person', 'UR2', 'before-r2-restore', ?)").run(nowMs);
  srcStore.db.prepare("INSERT INTO turns (id, session_key, kind, started_at, ended_at, outcome, thread) VALUES (?, ?, 'turn', ?, ?, 'completed', 1)").run("r2-saved-turn", "s:r2-rem", nowMs - 1000, nowMs);
  srcStore.db.prepare("INSERT INTO proposal_outcomes (thread, n, status, project, resolved_by, resolved_at, info_note, info_refs, info_synced, info_op_id) VALUES (1, 1, 'accepted', 'ProjR2', 'a@b.com', ?, 'note-r2', '[]', 0, ?)").run(nowMs, r13OpId);

  const exp = new Exporter({ db: srcDb, replica: join(srcDir, "replica"), dataDir: srcDir, origin: originId, now: () => nowMs });
  exp.setPlaces({ home: ws, workspaces: [{ workspace: ws, name: "src-r2" }] });
  let passRes = exp.pass(nothingTold());
  while (passRes.more) passRes = exp.pass(nothingTold());
  const head = passRes.heads[ws];
  assert.ok(head, "expected Exporter head");
  const genPath = genDir(ownDir(join(srcDir, "replica")), ws, head.gen);
  const filesSrcDir = join(srcDir, "exported-files");
  mkdirSync(filesSrcDir, { recursive: true });
  for (const hash of Object.keys(head.files)) {
    const p = exp.sourceOf(hash);
    if (p) copyFileSync(p, join(filesSrcDir, hash));
  }
  exp.close();
  srcStore.close();

  function stageRestore(dataDir: string): void {
    const copyDir = join(dataDir, "restore", "copy");
    mkdirSync(copyDir, { recursive: true });
    cpSync(genPath, join(copyDir, head.gen), { recursive: true });
    if (existsSync(filesSrcDir)) cpSync(filesSrcDir, join(copyDir, "files"), { recursive: true });
    writeFileSync(
      join(dataDir, "restore", "ready.json"),
      JSON.stringify({ origin: originId, workspace: ws, gen: head.gen, name: "src-r2", from: "peer-r2" }),
    );
  }

  function runInternalRestore(dataDir: string, dbPath: string, extraCmdPrefix = ""): ReturnType<typeof spawnSync> {
    if (extraCmdPrefix) {
      return spawnSync(
        "sh",
        ["-c", `${extraCmdPrefix} exec "$@"`, "--", pionBin, "--internal-replica-restore", "--db", dbPath, "--data", dataDir],
        { encoding: "utf8", timeout: 20_000 },
      );
    }
    return spawnSync(pionBin, ["--internal-replica-restore", "--db", dbPath, "--data", dataDir], {
      encoding: "utf8",
      timeout: 20_000,
    });
  }

  // (6c-no-db & 6c-empty-db) Cold start with staged restore/ready.json (no DB & pre-created empty v13 DB)
  for (const mode of ["no-db", "empty-db"] as const) {
    const dir = freshDir(`r2-6c-${mode}`);
    const dataDir = join(dir, "data");
    stageRestore(dataDir);
    const dbPath = join(dataDir, "stillfail.db");
    if (mode === "empty-db") {
      const db = new DatabaseSync(dbPath);
      db.exec("PRAGMA user_version = 13;");
      db.close();
    } else {
      assert.equal(existsSync(dbPath), false);
    }
    const res = runInternalRestore(dataDir, dbPath);
    assert.equal(res.status, 0, `6c-${mode} must succeed: ${res.stdout}\n${res.stderr}`);
    assert.equal(existsSync(join(dataDir, "restore")), false, `6c-${mode} must clean restore/`);
    const chk = new DatabaseSync(dbPath, { readOnly: true });
    const rows = chk.prepare("SELECT text FROM entries WHERE text = 'before-r2-restore'").all();
    chk.close();
    assert.ok(rows.length >= 1, `6c-${mode} must restore snapshot entry`);
  }

  // (6c-locked-existing-db) Locked DB -> exits non-zero, preserves DB bytes + journal_mode + restore/
  {
    const dir = freshDir("r2-6c-lock");
    const dataDir = join(dir, "data");
    stageRestore(dataDir);
    const dbPath = join(dataDir, "stillfail.db");
    const db = new DatabaseSync(dbPath);
    db.exec("PRAGMA journal_mode = DELETE; PRAGMA user_version = 13;");
    db.close();
    const origBytes = readFileSync(dbPath);
    const holder = new DatabaseSync(dbPath);
    holder.exec("BEGIN EXCLUSIVE;");
    try {
      const res = runInternalRestore(dataDir, dbPath);
      assert.notEqual(res.status, 0, `6c-locked must fail, got 0: ${res.stdout}\n${res.stderr}`);
      assert.equal(existsSync(join(dataDir, "restore", "ready.json")), true, "6c-locked preserves restore/ready.json");
      assert.equal(Buffer.compare(readFileSync(dbPath), origBytes), 0, "6c-locked leaves DB untouched");
    } finally {
      holder.exec("ROLLBACK;");
      holder.close();
    }
  }

  // (6d-io-fail-atomic-retry) Empty 0-table v13 DB + RLIMIT_FSIZE -> fails cleanly, 0 tables, then retry succeeds!
  {
    const dir = freshDir("r2-6d-fsize");
    const dataDir = join(dir, "data");
    stageRestore(dataDir);
    const dbPath = join(dataDir, "stillfail.db");
    const emptyDb = new DatabaseSync(dbPath);
    emptyDb.exec("PRAGMA user_version = 13;");
    emptyDb.close();
    const failRes = runInternalRestore(dataDir, dbPath, 'trap "" XFSZ; ulimit -f 304;');
    assert.notEqual(failRes.status, 0, `6d-fsize must fail under ulimit -f 304`);
    assert.equal(existsSync(join(dataDir, "restore", "ready.json")), true, "6d-fsize preserves restore/ready.json");
    const chk0 = new DatabaseSync(dbPath, { readOnly: true });
    const t0 = (chk0.prepare("SELECT COUNT(*) AS n FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'").get() as { n: number }).n;
    chk0.close();
    assert.equal(t0, 0, "6d-fsize leaves 0 tables after rollback");

    const okRes = runInternalRestore(dataDir, dbPath);
    assert.equal(okRes.status, 0, `6d-retry must succeed: ${okRes.stdout}\n${okRes.stderr}`);
    assert.equal(existsSync(join(dataDir, "restore")), false, "6d-retry cleans restore/");
  }

  // (6e-higher-user-version) user_version=99 -> exits non-zero, preserves DB bytes + restore/
  {
    const dir = freshDir("r2-6e-uv99");
    const dataDir = join(dir, "data");
    stageRestore(dataDir);
    const dbPath = join(dataDir, "stillfail.db");
    const db = new DatabaseSync(dbPath);
    db.exec("PRAGMA user_version = 99;");
    db.close();
    const origBytes = readFileSync(dbPath);
    const res = runInternalRestore(dataDir, dbPath);
    assert.notEqual(res.status, 0, "6e-uv99 must fail");
    assert.ok(`${res.stdout}\n${res.stderr}`.includes("unsupported_user_version:99"), `6e-uv99 stderr: ${res.stderr}`);
    assert.equal(Buffer.compare(readFileSync(dbPath), origBytes), 0, "6e-uv99 leaves DB bytes untouched");
    assert.equal(existsSync(join(dataDir, "restore", "ready.json")), true, "6e-uv99 preserves restore/ready.json");
  }

  // (6f-concurrent-writer) In-place BEGIN IMMEDIATE preserves inode & concurrent thread 73 commit!
  {
    const dir = freshDir("r2-6f-conc");
    const dataDir = join(dir, "data");
    stageRestore(dataDir);
    const dbPath = join(dataDir, "stillfail.db");
    const db = new DatabaseSync(dbPath);
    db.exec("PRAGMA journal_mode = WAL; PRAGMA user_version = 13;");
    db.close();
    const inoBefore = statSync(dbPath).ino;
    const writer = new DatabaseSync(dbPath);
    writer.exec("BEGIN IMMEDIATE; CREATE TABLE IF NOT EXISTS threads (id INTEGER PRIMARY KEY, surface TEXT NOT NULL, channel TEXT NOT NULL, thread_ts TEXT NOT NULL, title TEXT, auto_title TEXT, created_by TEXT, created_at INTEGER NOT NULL, home TEXT, hidden_at INTEGER, hidden_by TEXT, shown_at INTEGER, project TEXT, project_locked INTEGER NOT NULL DEFAULT 0); INSERT INTO threads (id, surface, channel, thread_ts, title, created_at) VALUES (73, 'chat', 'CHAT', '73.0', 'LocalThread73', 1700000000000);");
    const proc = spawn(pionBin, ["--internal-replica-restore", "--db", dbPath, "--data", dataDir], { stdio: "pipe" });
    await new Promise((r) => setTimeout(r, 250));
    writer.exec("COMMIT;");
    writer.close();
    const code = await new Promise<number | null>((resolve) => proc.on("close", resolve));
    assert.equal(code, 0, "6f-conc must succeed after short writer commit");
    assert.equal(statSync(dbPath).ino, inoBefore, "6f-conc must preserve inode");
    const chk = new DatabaseSync(dbPath, { readOnly: true });
    const row = chk.prepare("SELECT id, title FROM threads WHERE id = 73").get() as { id: number; title: string } | undefined;
    chk.close();
    assert.deepEqual(row ? { ...row } : null, { id: 73, title: "LocalThread73" });
  }

  // (6f-b-concurrent-writer-long-lock) Writer holds lock >2000ms -> exits non-zero, preserves restore/ + inode + thread 73!
  {
    const dir = freshDir("r2-6fb-lock");
    const dataDir = join(dir, "data");
    stageRestore(dataDir);
    const dbPath = join(dataDir, "stillfail.db");
    const db = new DatabaseSync(dbPath);
    db.exec("PRAGMA journal_mode = WAL; PRAGMA user_version = 13;");
    db.close();
    const inoBefore = statSync(dbPath).ino;
    const writer = new DatabaseSync(dbPath);
    writer.exec("BEGIN IMMEDIATE; CREATE TABLE IF NOT EXISTS threads (id INTEGER PRIMARY KEY, surface TEXT NOT NULL, channel TEXT NOT NULL, thread_ts TEXT NOT NULL, title TEXT, auto_title TEXT, created_by TEXT, created_at INTEGER NOT NULL, home TEXT, hidden_at INTEGER, hidden_by TEXT, shown_at INTEGER, project TEXT, project_locked INTEGER NOT NULL DEFAULT 0); INSERT INTO threads (id, surface, channel, thread_ts, title, created_at) VALUES (73, 'chat', 'CHAT', '73.0', 'LocalThread73Long', 1700000000000);");
    const proc = spawn(pionBin, ["--internal-replica-restore", "--db", dbPath, "--data", dataDir], { stdio: "pipe" });
    const code = await new Promise<number | null>((resolve) => proc.on("close", resolve));
    writer.exec("COMMIT;");
    writer.close();
    assert.notEqual(code, 0, "6f-b must exit non-zero on >2000ms writer lock");
    assert.equal(existsSync(join(dataDir, "restore", "ready.json")), true, "6f-b preserves restore/ready.json");
    assert.equal(statSync(dbPath).ino, inoBefore, "6f-b preserves inode");
    const chk = new DatabaseSync(dbPath, { readOnly: true });
    const row = chk.prepare("SELECT id, title FROM threads WHERE id = 73").get() as { id: number; title: string } | undefined;
    chk.close();
    assert.deepEqual(row ? { ...row } : null, { id: 73, title: "LocalThread73Long" });
  }

  // (6g-partial-4-core-tables-restores-turns)
  {
    const dir = freshDir("r2-6g-4tbl");
    const dataDir = join(dir, "data");
    stageRestore(dataDir);
    const dbPath = join(dataDir, "stillfail.db");
    Store.open(dbPath, join(dataDir, "archives")).close();
    const partial = new DatabaseSync(dbPath);
    const keep = new Set(["threads", "sessions", "entries", "thread_sessions"]);
    for (const v of partial.prepare("SELECT name FROM sqlite_master WHERE type='view'").all() as { name: string }[]) {
      partial.exec(`DROP VIEW IF EXISTS "${v.name}";`);
    }
    for (const tr of partial.prepare("SELECT name FROM sqlite_master WHERE type='trigger'").all() as { name: string }[]) {
      partial.exec(`DROP TRIGGER IF EXISTS "${tr.name}";`);
    }
    for (const t of partial.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'").all() as { name: string }[]) {
      if (!keep.has(t.name)) partial.exec(`DROP TABLE IF EXISTS "${t.name}";`);
    }
    partial.close();
    const res = runInternalRestore(dataDir, dbPath);
    assert.equal(res.status, 0, `6g-4tbl must succeed: ${res.stdout}\n${res.stderr}`);
    const chk = new DatabaseSync(dbPath, { readOnly: true });
    const turnRow = chk.prepare("SELECT outcome FROM turns WHERE id = 'r2-saved-turn'").get() as { outcome: string } | undefined;
    chk.close();
    assert.equal(turnRow?.outcome, "completed", "6g-4tbl must restore turns");
  }

  // (6h-zero-byte-and-missing-db-preserve-wal)
  for (const mode of ["zero-byte-db", "missing-db"] as const) {
    const dir = freshDir(`r2-6h-${mode}`);
    const dataDir = join(dir, "data");
    stageRestore(dataDir);
    const dbPath = join(dataDir, "stillfail.db");
    const walPath = `${dbPath}-wal`;
    if (mode === "zero-byte-db") writeFileSync(dbPath, Buffer.alloc(0));
    const fakeWal = Buffer.alloc(16384, 0x5a);
    writeFileSync(walPath, fakeWal);
    const res = runInternalRestore(dataDir, dbPath);
    assert.notEqual(res.status, 0, `6h-${mode} must exit non-zero`);
    assert.equal(Buffer.compare(readFileSync(walPath), fakeWal), 0, `6h-${mode} must preserve WAL bytes`);
    assert.equal(existsSync(join(dataDir, "restore", "ready.json")), true, `6h-${mode} must preserve restore/ready.json`);
  }

  // (6i-historical-v13-adds-missing-columns)
  {
    const dir = freshDir("r2-6i-cols");
    const dataDir = join(dir, "data");
    stageRestore(dataDir);
    const dbPath = join(dataDir, "stillfail.db");
    const db = new DatabaseSync(dbPath);
    db.exec(`
      PRAGMA user_version = 13;
      CREATE TABLE proposal_outcomes (thread INTEGER NOT NULL, n INTEGER NOT NULL, status TEXT NOT NULL, project TEXT, resolved_by TEXT NOT NULL, resolved_at INTEGER NOT NULL, info_note TEXT, info_refs TEXT, info_synced INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (thread, n));
    `);
    db.close();
    const res = runInternalRestore(dataDir, dbPath);
    assert.equal(res.status, 0, `6i-cols must succeed: ${res.stdout}\n${res.stderr}`);
    const verifyStore = Store.open(dbPath, join(dataDir, "archives"));
    const outcome = verifyStore.getUnsyncedAcceptOutcome(1, 1);
    verifyStore.close();
    assert.ok(outcome !== null && outcome.opId === r13OpId, "6i-cols must repair proposal_outcomes.info_op_id and restore it");
  }

  // (6j-v12-cold-restore-safety)
  // 1. Empty v12 DB -> `--internal-replica-restore` atomically upgrades to v13 and restores snapshot.
  // 2. Non-empty v12 DB -> Pion NEVER silently bumps `user_version` from 12 to 13 (protects v12 archive files).
  {
    const dirEmpty = freshDir("r2-6j-v12e");
    const dataEmpty = join(dirEmpty, "data");
    stageRestore(dataEmpty);
    const dbEmpty = join(dataEmpty, "stillfail.db");
    const d0 = new DatabaseSync(dbEmpty);
    d0.exec("PRAGMA user_version = 12;");
    d0.close();
    const resEmpty = runInternalRestore(dataEmpty, dbEmpty);
    assert.equal(resEmpty.status, 0, `6j-v12-empty must succeed: ${resEmpty.stdout}\n${resEmpty.stderr}`);
    assert.equal(existsSync(join(dataEmpty, "restore")), false, "6j-v12-empty must clean restore/");
    const chkEmpty = new DatabaseSync(dbEmpty, { readOnly: true });
    const verEmpty = (chkEmpty.prepare("PRAGMA user_version").get() as { user_version: number }).user_version;
    const remoteEmpty = chkEmpty.prepare("SELECT text FROM entries WHERE text = 'before-r2-restore'").all();
    chkEmpty.close();
    assert.equal(verEmpty, SCHEMA_VERSION, `6j-v12-empty must upgrade user_version to ${SCHEMA_VERSION}`);
    assert.ok(remoteEmpty.length >= 1, "6j-v12-empty must restore remote snapshot entry");

    const dirNonEmpty = freshDir("r2-6j-v12n");
    const dataNonEmpty = join(dirNonEmpty, "data");
    stageRestore(dataNonEmpty);
    const dbNonEmpty = join(dataNonEmpty, "stillfail.db");
    Store.open(dbNonEmpty, join(dataNonEmpty, "archive")).close();
    const d1 = new DatabaseSync(dbNonEmpty);
    d1.exec(`
      INSERT INTO threads (id, surface, channel, thread_ts, title, created_at) VALUES (73, 'chat', 'CHAT', '73.v12', 'LocalV12', ${nowMs});
      INSERT INTO entries (thread, n, kind, author_kind, author, text, at) VALUES (73, 1, 'message', 'person', 'local@example.com', 'local-v12-entry', ${nowMs});
      PRAGMA user_version = 12;
    `);
    d1.close();
    const resNonEmpty = runInternalRestore(dataNonEmpty, dbNonEmpty);
    assert.equal(resNonEmpty.status, 0, `6j-v12-nonempty restore completes without mutating user_version: ${resNonEmpty.stderr}`);
    const chkNonEmpty = new DatabaseSync(dbNonEmpty, { readOnly: true });
    const verNonEmpty = (chkNonEmpty.prepare("PRAGMA user_version").get() as { user_version: number }).user_version;
    const localRows = chkNonEmpty.prepare("SELECT text FROM entries WHERE text = 'local-v12-entry'").all();
    chkNonEmpty.close();
    assert.equal(verNonEmpty, 12, "6j-v12-nonempty must NEVER silently bump v12 user_version to 13");
    assert.ok(localRows.length >= 1, "6j-v12-nonempty preserves local v12 entry");
  }
});
