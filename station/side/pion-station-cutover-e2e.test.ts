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
  writeFileSync(join(dataDir, "config.json"), JSON.stringify({ engine: "pion" }));
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

test("W17A.7: External connects entry gate & in-place exec_replace fallback (live Node SIGUSR2 + SIGKILL crash recovery, cold launcher, cross-station connect.event, STRICT=1 refusal, disabled connects clean Pion boot & handover)", async () => {
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

  // Mock Slack HTTP + Socket Mode WS server.
  let slackHttpHits = 0;
  let slackWsConns = 0;
  const slackSrv = createHttpServer((req, res) => {
    slackHttpHits++;
    if (req.url?.includes("auth.test")) {
      res.writeHead(200, { "content-type": "application/json" }).end(
        JSON.stringify({ ok: true, team_id: "T_GATE", team: "GateTeam", user_id: "UBOT", bot_id: "BBOT", user: "bot" }),
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
    res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ ok: true }));
  });
  const slackWss = new WebSocketServer({ noServer: true });
  servers.push(slackWss, slackSrv);
  slackSrv.on("upgrade", (req, socket, head) => {
    slackWss.handleUpgrade(req, socket, head, (ws) => {
      slackWsConns++;
      ws.send(JSON.stringify({ type: "hello", num_connections: slackWsConns }));
    });
  });
  await new Promise<void>((resolve) => slackSrv.listen(0, "127.0.0.1", () => resolve()));
  const slackPort = (slackSrv.address() as AddressInfo).port;

  // --- Scenario 1 (Opus R5 `node-crash`): Live Node + Slack -> flip `engine: "pion"` + `SIGUSR2` -> `SIGKILL` Node crash recovery ---
  {
    const dir = freshDir("ext-gate-live-crash");
    const appDir = join(dir, "app");
    const dataDir = join(dir, "data");
    installReleaseDir(appDir, pionBin, readerBin, runnerBin, true);
    mkdirSync(join(dataDir, "mesh"), { recursive: true });

    const idRes = spawnSync(pionBin, ["id", "--data", dataDir], { encoding: "utf8" });
    assert.equal(idRes.status, 0, idRes.stderr);
    const stationId = idRes.stdout.trim();

    const enabledSlackCfg = {
      engine: "node",
      connects: [
        {
          id: "slack-main",
          bind: { runtime: "claude" },
          slack: {
            appToken: "xapp-1-w17a-gate",
            botToken: "xoxb-w17a-gate",
            baseUrl: `http://127.0.0.1:${slackPort}`,
          },
        },
      ],
    };
    writeFileSync(join(dataDir, "config.json"), JSON.stringify(enabledSlackCfg));
    writeFileSync(
      join(dataDir, "mesh", "cloud.json"),
      JSON.stringify({
        workspace: "ws-gate",
        workspace_name: "GateWS",
        station: stationId,
        name: "gate-station",
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

    const pid1 = await until(
      "Scenario 1 initial Node pid",
      () => {
        const p = readHubPid(dataDir);
        return p > 0 && isAlive(p) && (readPorts(dataDir).admin ?? 0) > 0 ? p : null;
      },
      30_000,
    );
    const port1 = readPorts(dataDir).admin!;
    assert.equal((await httpCall(port1, "GET", "/healthz")).status, 200);

    // Flip to `"engine": "pion"` and send `SIGUSR2`: Pion MUST exec_replace in-place into Node!
    writeFileSync(join(dataDir, "config.json"), JSON.stringify({ ...enabledSlackCfg, engine: "pion" }));
    launcher.kill("SIGUSR2");

    await until(
      "Scenario 1 exec_replace logged on SIGUSR2",
      () => logs.join("").includes("external connects active (slack:slack-main); exec-replacing into Node station"),
      15_000,
    );
    const pid2 = await until(
      "Scenario 1 exec-replaced Node pid2 after SIGUSR2",
      () => {
        const p = readHubPid(dataDir);
        return p > 0 && p !== pid1 && isAlive(p) ? p : null;
      },
      20_000,
    );
    const port2 = readPorts(dataDir).admin!;
    assert.equal((await httpCall(port2, "GET", "/healthz")).status, 200);

    const clientEp = await bindClientEp(mesh);
    const jwt = signMemberJwt({ ws: "ws-gate", device: clientEp.id(), sub: "u-gate", email: "g@example.com", name: "Gate", role: "owner" });
    const { conn: conn2 } = await until("Scenario 1 Node admin /admin/api/ways after SIGUSR2", () =>
      openAdminConn(clientEp, stationId, `127.0.0.1:${udpPort}`, jwt),
    );
    assert.equal((await adminRequest(conn2, "GET", "/admin/api/ways")).status, 200);
    conn2.close(0, "done");

    // Simulate sudden Node crash (`SIGKILL`): Launcher restarts Pion -> exec_replace back into Node within 10s (NO 5-failure give-up)!
    process.kill(pid2, "SIGKILL");
    const pid3 = await until(
      "Scenario 1 Node pid3 recovered after SIGKILL crash",
      () => {
        const p = readHubPid(dataDir);
        return p > 0 && p !== pid2 && isAlive(p) ? p : null;
      },
      15_000,
    );
    const port3 = readPorts(dataDir).admin!;
    await until("Scenario 1 /healthz 200 after SIGKILL recovery", async () => {
      try {
        const r = await httpCall(port3, "GET", "/healthz");
        return r.status === 200 ? true : null;
      } catch {
        return null;
      }
    }, 10_000);
    assert.equal(isAlive(pid3), true);
    assert.equal(logs.join("").includes("giving up"), false, `launcher must NOT give up: ${logs.join("")}`);

    launcher.kill("SIGTERM");
    await until("Scenario 1 launcher exit", () => launcher.exitCode !== null || launcher.signalCode !== null);
  }

  // --- Scenario 2 (Opus R5 `cold-launcher`): Cold start via real Launcher with `"engine": "pion"` + enabled Slack ---
  {
    const dir = freshDir("ext-gate-cold-launcher");
    const appDir = join(dir, "app");
    const dataDir = join(dir, "data");
    installReleaseDir(appDir, pionBin, readerBin, runnerBin, true);
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
            id: "slack-cold",
            bind: { runtime: "claude" },
            slack: {
              appToken: "xapp-1-w17a-cold",
              botToken: "xoxb-w17a-cold",
              baseUrl: `http://127.0.0.1:${slackPort}`,
            },
          },
        ],
      }),
    );
    writeFileSync(
      join(dataDir, "mesh", "cloud.json"),
      JSON.stringify({
        workspace: "ws-cold-l",
        workspace_name: "ColdLauncherWS",
        station: stationId,
        name: "cold-launcher-station",
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

    const nodePid = await until(
      "Scenario 2 cold-launcher exec-replaced Node pid",
      () => {
        const p = readHubPid(dataDir);
        return p > 0 && isAlive(p) && (readPorts(dataDir).admin ?? 0) > 0 ? p : null;
      },
      30_000,
    );
    const port = readPorts(dataDir).admin!;
    assert.equal((await httpCall(port, "GET", "/healthz")).status, 200);
    assert.ok(
      logs.join("").includes("external connects active (slack:slack-cold); exec-replacing into Node station"),
      `expected cold-launcher exec_replace log, got: ${logs.join("")}`,
    );
    assert.equal(logs.join("").includes("giving up"), false);

    const clientEp = await bindClientEp(mesh);
    const jwt = signMemberJwt({ ws: "ws-cold-l", device: clientEp.id(), sub: "u-cl", email: "cl@example.com", name: "CL", role: "owner" });
    const { conn } = await until("Scenario 2 Node admin /admin/api/ways", () =>
      openAdminConn(clientEp, stationId, `127.0.0.1:${udpPort}`, jwt),
    );
    assert.equal((await adminRequest(conn, "GET", "/admin/api/ways")).status, 200);
    conn.close(0, "done");
    assert.equal(isAlive(nodePid), true);

    launcher.kill("SIGTERM");
    await until("Scenario 2 launcher exit", () => launcher.exitCode !== null || launcher.signalCode !== null);
  }

  // --- Scenario 3 (Astra R5 P1): Cross-station receiver (`connects: []` + `connect.event` -> `remote-connects.json`) -> `engine: "pion"` + `SIGUSR2` -> 2nd `connect.event` edit ---
  {
    const dir = freshDir("ext-gate-remote-connects");
    const appDir = join(dir, "app");
    const dataDir = join(dir, "data");
    installReleaseDir(appDir, pionBin, readerBin, runnerBin, true);
    mkdirSync(join(dataDir, "mesh"), { recursive: true });

    const idRes = spawnSync(pionBin, ["id", "--data", dataDir], { encoding: "utf8" });
    assert.equal(idRes.status, 0, idRes.stderr);
    const stationId = idRes.stdout.trim();

    const peerEp = await bindClientEp(mesh);
    const peerId = peerEp.id();

    // Mock cloud presence WS so Node's `cloud.peersCurrent` is true and accepts `stillfail/station/2` peer RPCs!
    const cloudHttp = createHttpServer((_req, res) => {
      res.writeHead(404).end();
    });
    const cloudWss = new WebSocketServer({ server: cloudHttp });
    servers.push(cloudHttp, cloudWss);
    cloudWss.on("connection", (wsSock) => {
      wsSock.send(
        JSON.stringify({
          type: "state",
          workspace: "ws-rem",
          workspace_name: "RemWS",
          name: "rem-receiver",
          peers: [{ id: peerId, name: "peer-sender", relay: null }],
          workspaces: [],
          revocations: [],
        }),
      );
    });
    await new Promise<void>((r) => cloudHttp.listen(0, "127.0.0.1", () => r()));
    const cloudPort = (cloudHttp.address() as AddressInfo).port;

    writeFileSync(join(dataDir, "config.json"), JSON.stringify({ engine: "node", connects: [] }));
    writeFileSync(
      join(dataDir, "mesh", "cloud.json"),
      JSON.stringify({
        origin: `http://127.0.0.1:${cloudPort}`,
        workspace: "ws-rem",
        workspace_name: "RemWS",
        station: stationId,
        name: "rem-receiver",
        peers: [{ id: peerId, name: "peer-sender", relay: null }],
        relay_urls: [],
        grant_keys: grantKeys,
      }),
    );

    // Pre-seed a Slack thread + message in `stillfail.db` (without `remote-connects.json` yet)
    // so both `connect.event` edits persist directly without triggering outbound peer `connect.call` lookups.
    {
      const seed = Store.open(join(dataDir, "stillfail.db"), join(dataDir, "archives"));
      const now = Date.now();
      seed.db.prepare("INSERT INTO threads (id, surface, channel, thread_ts, title, created_at) VALUES (1, 'slack:T_REM', 'C_REM', '100.001', 'RemoteThread', ?)").run(now);
      seed.db.prepare("INSERT INTO entries (thread, n, kind, ts, author_kind, author, text, at) VALUES (1, 1, 'message', '100.001', 'person', 'U_REM', 'initial-remote-msg', ?)").run(now);
      seed.close();
    }

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

    const pid1 = await until(
      "Scenario 3 initial Node pid",
      () => {
        const p = readHubPid(dataDir);
        return p > 0 && isAlive(p) && (readPorts(dataDir).admin ?? 0) > 0 ? p : null;
      },
      30_000,
    );

    const described = {
      kind: "slack",
      workspace: "ws-rem",
      mode: "multi-session",
      requireMention: false,
      bind: { runtime: "claude" },
      botUserId: "UBOT_REM",
      botName: "rembot",
      identity: null,
      platform: "slack",
      team: "T_REM",
      cards: true,
      loginCards: false,
      mention: ["<@", ">"],
      link: null,
      has: [],
    };
    const known = { id: "slack-remote", origin: peerId };

    // 1st `connect.event`: Node learns the remote connect and writes `<data>/remote-connects.json`.
    let lastEv1Err = "";
    const ev1Resp = await until("Scenario 3 1st connect.event peer RPC", async () => {
      try {
        return await peerRpc(peerEp, stationId, `127.0.0.1:${udpPort}`, "ws-rem", {
          method: "connect.event",
          workspace: "ws-rem",
          connect: known,
          described,
          event: {
            type: "changed",
            channel: "C_REM",
            threadTs: "100.001",
            ts: "100.001",
            text: "first-remote-edit",
          },
        });
      } catch (e) {
        lastEv1Err = String(e);
        return null;
      }
    }, 15_000).catch((err) => {
      throw new Error(`${String(err)} (lastEv1Err=${lastEv1Err})`);
    });
    assert.deepEqual(ev1Resp.result, { ok: true });

    await until("Scenario 3 remote-connects.json written by Node", () => {
      const p = join(dataDir, "remote-connects.json");
      if (!existsSync(p)) return null;
      try {
        const obj = JSON.parse(readFileSync(p, "utf8"));
        return Object.keys(obj).length > 0 ? obj : null;
      } catch {
        return null;
      }
    }, 10_000);

    // Flip `config.json` to `"engine": "pion"` (keeping `connects: []`!) and trigger `SIGUSR2`.
    writeFileSync(join(dataDir, "config.json"), JSON.stringify({ engine: "pion", connects: [] }));
    launcher.kill("SIGUSR2");

    await until(
      "Scenario 3 exec_replace logged for remote-connects.json",
      () => logs.join("").includes("remote-connects:1") && logs.join("").includes("exec-replacing into Node station"),
      15_000,
    );
    const pid2 = await until(
      "Scenario 3 exec-replaced Node pid2 after SIGUSR2",
      () => {
        const p = readHubPid(dataDir);
        return p > 0 && p !== pid1 && isAlive(p) ? p : null;
      },
      20_000,
    );
    assert.equal((await httpCall(readPorts(dataDir).admin!, "GET", "/healthz")).status, 200);
    assert.equal(isAlive(pid2), true);

    // 2nd `connect.event` (edit) MUST succeed on the exec-replaced Node station and persist the edited text!
    const ev2Resp = await until("Scenario 3 2nd connect.event edit peer RPC", async () => {
      try {
        return await peerRpc(peerEp, stationId, `127.0.0.1:${udpPort}`, "ws-rem", {
          method: "connect.event",
          workspace: "ws-rem",
          connect: known,
          described,
          event: {
            type: "changed",
            channel: "C_REM",
            threadTs: "100.001",
            ts: "100.001",
            text: "edited-remote-message-after-sigusr2",
          },
        });
      } catch {
        return null;
      }
    }, 15_000);
    assert.deepEqual(ev2Resp.result, { ok: true });

    launcher.kill("SIGTERM");
    await until("Scenario 3 launcher exit", () => launcher.exitCode !== null || launcher.signalCode !== null);

    // Read back edited message via Node `Store.open`!
    const verifyStore = Store.open(join(dataDir, "stillfail.db"), join(dataDir, "archives"));
    const rows = verifyStore.db.prepare("SELECT text FROM entries WHERE text LIKE '%edited-remote-message-after-sigusr2%'").all() as { text: string }[];
    verifyStore.close();
    assert.ok(rows.length >= 1, "expected 2nd connect.event edited text persisted in stillfail.db");
  }

  // --- Scenario 4: `STILLFAIL_STATION_ENGINE_STRICT=1` cold refusal (omitted/null/"chat" Slack + Feishu + Comma + Group) ---
  {
    const coldDir = freshDir("ext-gate-strict");
    mkdirSync(join(coldDir, "mesh"), { recursive: true });
    const idRes = spawnSync(pionBin, ["id", "--data", coldDir], { encoding: "utf8" });
    assert.equal(idRes.status, 0, idRes.stderr);
    const coldId = idRes.stdout.trim();
    writeFileSync(
      join(coldDir, "config.json"),
      JSON.stringify({
        engine: "pion",
        connects: [
          { id: "sl-omit", slack: { appToken: "xapp-1-t", botToken: "xoxb-t", baseUrl: `http://127.0.0.1:${slackPort}` } },
          { id: "sl-null", kind: null },
          { id: "sl-chat", kind: "chat" },
          { id: "fs-1", kind: "feishu", feishu: { appId: "cli_1", appSecret: "sec_1" } },
          { id: "cm-1", kind: "comma", comma: { server: "http://127.0.0.1:9", token: "tok" } },
          { id: "gr-1", kind: "group", group: { server: HEX32, key: HEX32, memberId: "m1" } },
        ],
      }),
    );
    writeFileSync(
      join(coldDir, "mesh", "cloud.json"),
      JSON.stringify({
        workspace: "ws-cold",
        workspace_name: "ColdWS",
        station: coldId,
        name: "cold-station",
        peers: [],
        relay_urls: [],
        grant_keys: grantKeys,
      }),
    );

    const hitsBefore = slackHttpHits;
    const wsBefore = slackWsConns;
    const coldRun = spawnSync(pionBin, ["run", "--data", coldDir, "--port", "0"], {
      env: { ...process.env, STILLFAIL_NO_DISCOVERY: "1", STILLFAIL_NO_DHT: "1", STILLFAIL_STATION_ENGINE_STRICT: "1" },
      encoding: "utf8",
      timeout: 15_000,
    });
    assert.notEqual(coldRun.status, 0, "STRICT=1 cold start with enabled external connects must exit non-zero");
    const combined = `${coldRun.stdout}\n${coldRun.stderr}`;
    assert.ok(
      combined.includes("slack:sl-omit, slack:sl-null, slack:sl-chat, feishu:fs-1, comma:cm-1, group:gr-1"),
      `expected STRICT refusal naming all 6 connects, got: ${combined}`,
    );
    assert.equal(existsSync(join(coldDir, "stillfail.db")), false, "STRICT refusal must NOT create stillfail.db");
    assert.equal(slackHttpHits, hitsBefore, "STRICT refusal must NOT contact mock Slack HTTP");
    assert.equal(slackWsConns, wsBefore, "STRICT refusal must NOT open mock Slack WS");
  }

  // --- Scenario 5: No enabled connects & no `remote-connects.json` -> clean pure Pion `whole_daemon` boot, handover & shutdown ---
  {
    const dir = freshDir("ext-gate-disabled");
    const appDir = join(dir, "app");
    const dataDir = join(dir, "data");
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
          { id: "slack-off", enabled: false, slack: { appToken: "xapp-1-t", botToken: "xoxb-t", baseUrl: `http://127.0.0.1:${slackPort}` } },
          { id: "feishu-off", kind: "feishu", enabled: false },
        ],
      }),
    );
    writeFileSync(
      join(dataDir, "mesh", "cloud.json"),
      JSON.stringify({
        workspace: "ws-dis",
        workspace_name: "DisWS",
        station: stationId,
        name: "dis-station",
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

    const pid1 = await until("disabled-connects pion pid1", () => {
      const p = readHubPid(dataDir);
      return p > 0 && isAlive(p) ? p : null;
    });

    const clientEp = await bindClientEp(mesh);
    const jwt = signMemberJwt({ ws: "ws-dis", device: clientEp.id(), sub: "u-dis", email: "d@example.com", name: "Dis", role: "owner" });
    const { conn } = await until("disabled-connects admin connect", () =>
      openAdminConn(clientEp, stationId, `127.0.0.1:${udpPort}`, jwt),
    );
    const stResp = await adminRequest(conn, "GET", "/status");
    assert.equal(stResp.status, 200);
    const stJson = JSON.parse(stResp.body.toString("utf8"));
    assert.equal(stJson.edge?.connects?.enabledInConfig, 0);
    assert.equal(stJson.edge?.connects?.total, 0);
    assert.equal(stJson.edge?.connects?.running, 0);
    conn.close(0, "done");

    // `SIGUSR2` handover + `SIGTERM` clean shutdown with 0 orphans & 0 FD leak!
    const fdBefore = openFdCount(pid1);
    launcher.kill("SIGUSR2");
    const pid2 = await until("disabled-connects pion pid2 after SIGUSR2", () => {
      const p = readHubPid(dataDir);
      return p > 0 && p !== pid1 && isAlive(p) ? p : null;
    });
    await until("old pion pid1 exited", () => !isAlive(pid1), 10_000);
    const fdAfter = openFdCount(pid2);
    if (fdBefore > 0 && fdAfter > 0) {
      assert.ok(Math.abs(fdAfter - fdBefore) <= 12, `unexpected FD delta across handover: before=${fdBefore} after=${fdAfter}`);
    }

    launcher.kill("SIGTERM");
    await until("disabled-connects launcher exit", () => launcher.exitCode !== null || launcher.signalCode !== null);
    await until("disabled-connects pion pid2 exited", () => !isAlive(pid2));
  }

  // --- Scenario 6 (Astra R7 6a / 6b / 6c): Pending `<data>/restore/ready.json` decided BEFORE `ready` ---
  {
    const srcDir = freshDir("ext-gate-r8-src");
    const srcDb = join(srcDir, "stillfail.db");
    const ws = "ws-r8-rest";
    const nowMs = Date.now();
    const peerEp = await bindClientEp(mesh);
    const peerId = peerEp.id();
    const remoteConnectId = `slack-r8@${peerId}`;

    const srcStore = Store.open(srcDb, join(srcDir, "archives"));
    srcStore.db
      .prepare(
        "INSERT INTO sessions (key, connect, scope, title, runtime, profile, workspace, token, created_at, last_active_at, cwd, ws) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
      )
      .run("s:r8-rem", remoteConnectId, "s:r8-rem", "RestoredRemote", "claude", "default", srcDir, randomBytes(32).toString("hex"), nowMs, nowMs, srcDir, ws);
    srcStore.db
      .prepare("INSERT INTO threads (id, surface, channel, thread_ts, title, created_at) VALUES (1, 'slack:T_R8', 'C_R8', '200.001', 'RestoredRemoteThread', ?)")
      .run(nowMs);
    srcStore.db
      .prepare("INSERT INTO thread_sessions (thread, session, connect, joined_at) VALUES (1, 's:r8-rem', ?, ?)")
      .run(remoteConnectId, nowMs);
    srcStore.db
      .prepare("INSERT INTO entries (thread, n, kind, ts, author_kind, author, text, at) VALUES (1, 1, 'message', '200.001', 'person', 'U_R8', 'before-r8-restore', ?)")
      .run(nowMs);
    const r13OpId = "op-r13-uuid-1234";
    srcStore.db
      .prepare("INSERT INTO turns (id, session_key, kind, started_at, ended_at, outcome, thread) VALUES (?, ?, 'turn', ?, ?, 'completed', 1)")
      .run("r11-saved-turn", "s:r8-rem", nowMs - 1000, nowMs);
    srcStore.db
      .prepare(
        "INSERT INTO proposal_outcomes (thread, n, status, project, resolved_by, resolved_at, info_note, info_refs, info_synced, info_op_id) VALUES (1, 1, 'accepted', 'ProjR13', 'alice@example.com', ?, 'note-r13', '[]', 0, ?)",
      )
      .run(nowMs, r13OpId);

    const originId = "b".repeat(64);
    const exp = new Exporter({ db: srcDb, replica: join(srcDir, "replica"), dataDir: srcDir, origin: originId, now: () => nowMs });
    exp.setPlaces({ home: ws, workspaces: [{ workspace: ws, name: "src-r8" }] });
    let passRes = exp.pass(nothingTold());
    while (passRes.more) passRes = exp.pass(nothingTold());
    const head = passRes.heads[ws];
    assert.ok(head, "expected Exporter head for Scenario 6");
    const genPath = genDir(ownDir(join(srcDir, "replica")), ws, head.gen);
    const filesSrcDir = join(srcDir, "exported-files");
    mkdirSync(filesSrcDir, { recursive: true });
    for (const hash of Object.keys(head.files)) {
      const p = exp.sourceOf(hash);
      if (p) copyFileSync(p, join(filesSrcDir, hash));
    }
    exp.close();
    srcStore.close();

    const stageR8Restore = (dataDir: string, merge = false): void => {
      const copyDir = join(dataDir, "restore", "copy");
      mkdirSync(copyDir, { recursive: true });
      cpSync(genPath, join(copyDir, head.gen), { recursive: true });
      cpSync(filesSrcDir, join(copyDir, "files"), { recursive: true });
      writeFileSync(
        join(dataDir, "restore", "ready.json"),
        JSON.stringify({ origin: originId, workspace: ws, gen: head.gen, name: "src-r8", from: peerId, ...(merge ? { merge: true } : {}) }),
      );
    };

    const describedR8 = {
      kind: "slack",
      workspace: ws,
      mode: "multi-session",
      requireMention: false,
      bind: { runtime: "claude" },
      botUserId: "UBOT_R8",
      botName: "r8bot",
      identity: null,
      platform: "slack",
      team: "T_R8",
      cards: true,
      loginCards: false,
      mention: ["<@", ">"],
      link: null,
      has: [],
    };

    const cloudHttp = createHttpServer((_req, res) => {
      res.writeHead(404).end();
    });
    const cloudWss = new WebSocketServer({ server: cloudHttp });
    servers.push(cloudHttp, cloudWss);
    cloudWss.on("connection", (wsSock) => {
      wsSock.send(
        JSON.stringify({
          type: "state",
          workspace: ws,
          workspace_name: "R8RestWS",
          name: "r8-rest-station",
          peers: [{ id: peerId, name: "peer-r8", relay: null }],
          workspaces: [],
          revocations: [],
        }),
      );
    });
    await new Promise<void>((r) => cloudHttp.listen(0, "127.0.0.1", () => r()));
    const cloudPort = (cloudHttp.address() as AddressInfo).port;

    // (6a) Live Node + staged `restore/ready.json` + STRICT=1 + flip `engine: "pion"` + SIGUSR2:
    // Pion exits 1 BEFORE `ready`, original Node PID stays alive with 100% 200 on `/healthz` + `/admin/api/ways`!
    {
      const dir = freshDir("ext-gate-r8-6a");
      const appDir = join(dir, "app");
      const dataDir = join(dir, "data");
      installReleaseDir(appDir, pionBin, readerBin, runnerBin, true);
      mkdirSync(join(dataDir, "mesh"), { recursive: true });
      const idRes = spawnSync(pionBin, ["id", "--data", dataDir], { encoding: "utf8" });
      assert.equal(idRes.status, 0, idRes.stderr);
      const stationId = idRes.stdout.trim();
      writeFileSync(join(dataDir, "config.json"), JSON.stringify({ engine: "node", connects: [] }));
      writeFileSync(
        join(dataDir, "mesh", "cloud.json"),
        JSON.stringify({
          origin: `http://127.0.0.1:${cloudPort}`,
          workspace: ws,
          workspace_name: "R8RestWS",
          station: stationId,
          name: "r8-6a",
          peers: [{ id: peerId, name: "peer-r8", relay: null }],
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
          STILLFAIL_STATION_ENGINE_STRICT: "1",
        },
        stdio: ["ignore", "pipe", "pipe"],
      });
      children.push(launcher);
      launcher.stdout.on("data", (d) => logs.push(String(d)));
      launcher.stderr.on("data", (d) => logs.push(String(d)));

      const pid1 = await until("6a initial Node pid", () => {
        const p = readHubPid(dataDir);
        return p > 0 && isAlive(p) && (readPorts(dataDir).admin ?? 0) > 0 ? p : null;
      }, 30_000);
      const port1 = readPorts(dataDir).admin!;

      stageR8Restore(dataDir);
      writeFileSync(join(dataDir, "config.json"), JSON.stringify({ engine: "pion", connects: [] }));
      launcher.kill("SIGUSR2");

      await until(
        "6a STRICT=1 refusal logged before ready",
        () => logs.join("").includes("restore:pending-ready-json"),
        15_000,
      );
      assert.equal(readHubPid(dataDir), pid1, "6a original Node PID must remain unchanged");
      assert.equal(isAlive(pid1), true, "6a original Node must remain alive");
      assert.equal(logs.join("").includes("giving up"), false);

      const clientEp = await bindClientEp(mesh);
      const jwt = signMemberJwt({ ws, device: clientEp.id(), sub: "u-6a", email: "6a@example.com", name: "6a", role: "owner" });
      const { conn } = await until("6a Node admin /admin/api/ways", () =>
        openAdminConn(clientEp, stationId, `127.0.0.1:${udpPort}`, jwt),
      );
      for (let i = 0; i < 8; i++) {
        assert.equal((await httpCall(port1, "GET", "/healthz")).status, 200);
        assert.equal((await adminRequest(conn, "GET", "/admin/api/ways")).status, 200);
      }
      conn.close(0, "done");

      launcher.kill("SIGTERM");
      await until("6a launcher exit", () => launcher.exitCode !== null || launcher.signalCode !== null);
    }

    // (6b) Live Node + staged `restore/ready.json` + default mode + flip `engine: "pion"` + SIGUSR2:
    // Smooth Node->Node handover via in-place `exec_replace` with ZERO `/healthz` resets/timeouts + 1st `connect.event` edit persists!
    {
      const dir = freshDir("ext-gate-r8-6b");
      const appDir = join(dir, "app");
      const dataDir = join(dir, "data");
      installReleaseDir(appDir, pionBin, readerBin, runnerBin, true);
      mkdirSync(join(dataDir, "mesh"), { recursive: true });
      const idRes = spawnSync(pionBin, ["id", "--data", dataDir], { encoding: "utf8" });
      assert.equal(idRes.status, 0, idRes.stderr);
      const stationId = idRes.stdout.trim();
      writeFileSync(join(dataDir, "config.json"), JSON.stringify({ engine: "node", connects: [] }));
      writeFileSync(
        join(dataDir, "mesh", "cloud.json"),
        JSON.stringify({
          origin: `http://127.0.0.1:${cloudPort}`,
          workspace: ws,
          workspace_name: "R8RestWS",
          station: stationId,
          name: "r8-6b",
          peers: [{ id: peerId, name: "peer-r8", relay: null }],
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

      const pid1 = await until("6b initial Node pid", () => {
        const p = readHubPid(dataDir);
        return p > 0 && isAlive(p) && (readPorts(dataDir).admin ?? 0) > 0 ? p : null;
      }, 30_000);
      const adminPort = readPorts(dataDir).admin!;
      assert.equal((await httpCall(adminPort, "GET", "/healthz")).status, 200);

      // Concurrent `/healthz` sampler across the entire `SIGUSR2` handover: ZERO resets / ZERO timeouts!
      let sampling = true;
      let sampleOk = 0;
      const sampleErrs: string[] = [];
      const sampler = (async () => {
        while (sampling) {
          try {
            const r = await httpCall(adminPort, "GET", "/healthz", { connection: "close" });
            if (r.status === 200) sampleOk++;
            else sampleErrs.push(`status=${r.status}`);
          } catch (e) {
            sampleErrs.push(String(e));
          }
          await new Promise((r) => setTimeout(r, 40));
        }
      })();

      stageR8Restore(dataDir);
      writeFileSync(join(dataDir, "config.json"), JSON.stringify({ engine: "pion", connects: [] }));
      launcher.kill("SIGUSR2");

      await until(
        "6b exec_replace logged for restore:pending-ready-json",
        () => logs.join("").includes("external connects active (restore:pending-ready-json); exec-replacing into Node station"),
        15_000,
      );
      const pid2 = await until("6b new Node pid2 after SIGUSR2", () => {
        const p = readHubPid(dataDir);
        return p > 0 && p !== pid1 && isAlive(p) ? p : null;
      }, 25_000);
      await until("6b old Node pid1 exited", () => !isAlive(pid1), 15_000);
      sampling = false;
      await sampler;
      assert.ok(sampleOk >= 3, `expected >= 3 /healthz samples during handover, got ${sampleOk}`);
      assert.deepEqual(sampleErrs, [], `6b handover must have ZERO /healthz resets/errors, got: ${sampleErrs.join("; ")}`);
      assert.equal(isAlive(pid2), true);

      const evResp = await until("6b connect.event edit on new Node", async () => {
        try {
          return await peerRpc(peerEp, stationId, `127.0.0.1:${udpPort}`, ws, {
            method: "connect.event",
            workspace: ws,
            connect: { id: "slack-r8", origin: peerId },
            described: describedR8,
            event: {
              type: "changed",
              channel: "C_R8",
              threadTs: "200.001",
              ts: "200.001",
              text: "edited-after-6b-sigusr2-restore",
            },
          });
        } catch {
          return null;
        }
      }, 15_000);
      assert.deepEqual(evResp.result, { ok: true });

      launcher.kill("SIGTERM");
      await until("6b launcher exit", () => launcher.exitCode !== null || launcher.signalCode !== null);

      const verifyStore = Store.open(join(dataDir, "stillfail.db"), join(dataDir, "archives"));
      const editedRows = verifyStore.db
        .prepare("SELECT text FROM entries WHERE text LIKE '%edited-after-6b-sigusr2-restore%'")
        .all() as { text: string }[];
      verifyStore.close();
      assert.ok(editedRows.length >= 1, "6b expected edited text persisted in stillfail.db");
    }

    // (6c-no-db & 6c-empty-db) Cold start + staged `restore/ready.json` + default mode:
    // Both with NO `stillfail.db` at all (`6c-no-db`) and with a pre-created empty schema DB (`6c-empty-db`),
    // Pion immediately `exec_replace`s into Node -> `restored.json.error === null` -> first `/healthz 200`
    // served by Node -> restored cross-station session present -> `connect.event` edit persists!
    for (const mode of ["6c-no-db", "6c-empty-db"] as const) {
      const dir = freshDir(`ext-gate-r9-${mode}`);
      const appDir = join(dir, "app");
      const dataDir = join(dir, "data");
      installReleaseDir(appDir, pionBin, readerBin, runnerBin, true);
      mkdirSync(join(dataDir, "mesh"), { recursive: true });
      const idRes = spawnSync(pionBin, ["id", "--data", dataDir], { encoding: "utf8" });
      assert.equal(idRes.status, 0, idRes.stderr);
      const stationId = idRes.stdout.trim();
      if (mode === "6c-empty-db") {
        Store.open(join(dataDir, "stillfail.db"), join(dataDir, "archives")).close();
      } else {
        assert.equal(existsSync(join(dataDir, "stillfail.db")), false, "6c-no-db must start with NO stillfail.db");
      }
      stageR8Restore(dataDir);
      writeFileSync(join(dataDir, "config.json"), JSON.stringify({ engine: "pion", connects: [] }));
      writeFileSync(
        join(dataDir, "mesh", "cloud.json"),
        JSON.stringify({
          origin: `http://127.0.0.1:${cloudPort}`,
          workspace: ws,
          workspace_name: "R8RestWS",
          station: stationId,
          name: `r9-${mode}`,
          peers: [{ id: peerId, name: "peer-r8", relay: null }],
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

      await until(
        `${mode} immediate exec_replace into Node on cold restore`,
        () => logs.join("").includes("external connects active (restore:pending-ready-json); exec-replacing into Node station"),
        20_000,
      );
      const nodePid = await until(
        `${mode} Node pid serving /healthz 200`,
        async () => {
          const p = readHubPid(dataDir);
          const port = readPorts(dataDir).admin ?? 0;
          if (p > 0 && isAlive(p) && port > 0) {
            try {
              const r = await httpCall(port, "GET", "/healthz");
              if (r.status === 200) return p;
            } catch {}
          }
          return null;
        },
        25_000,
      );
      assert.equal(isAlive(nodePid), true);
      await until(
        `${mode} Node replica restore completed`,
        () => (existsSync(join(dataDir, "replica", "restored.json")) ? true : null),
        15_000,
      );
      const restoredOut = JSON.parse(readFileSync(join(dataDir, "replica", "restored.json"), "utf8"));
      assert.equal(restoredOut.error, null, `${mode} restored.json must have error === null, got: ${JSON.stringify(restoredOut)}`);

      const editedText = `edited-after-${mode}-cold-restore`;
      const evResp = await until(`${mode} connect.event edit on Node`, async () => {
        try {
          return await peerRpc(peerEp, stationId, `127.0.0.1:${udpPort}`, ws, {
            method: "connect.event",
            workspace: ws,
            connect: { id: "slack-r8", origin: peerId },
            described: describedR8,
            event: {
              type: "changed",
              channel: "C_R8",
              threadTs: "200.001",
              ts: "200.001",
              text: editedText,
            },
          });
        } catch {
          return null;
        }
      }, 15_000);
      assert.deepEqual(evResp.result, { ok: true });

      launcher.kill("SIGTERM");
      await until(`${mode} launcher exit`, () => launcher.exitCode !== null || launcher.signalCode !== null);

      const verifyStore = Store.open(join(dataDir, "stillfail.db"), join(dataDir, "archives"));
      const sessRow = verifyStore.getSession("s:r8-rem");
      assert.ok(sessRow !== null && sessRow.connect === remoteConnectId, `${mode} expected restored cross-station session s:r8-rem`);
      const editedRows = verifyStore.db
        .prepare("SELECT text FROM entries WHERE text LIKE ?")
        .all(`%${editedText}%`) as { text: string }[];
      verifyStore.close();
      assert.ok(editedRows.length >= 1, `${mode} expected edited text persisted in stillfail.db`);
    }

    // (6c-locked-existing-db) Opus R10 P2: Existing rollback-journal DB locked with `BEGIN EXCLUSIVE`
    // + pending `restore/ready.json` -> Pion MUST exit 1 without opening DB for writes, preserving
    // `<data>/restore/`, byte-identical DB contents, and `journal_mode=delete`!
    {
      const dir = freshDir("ext-gate-r11-locked-db");
      const appDir = join(dir, "app");
      const dataDir = join(dir, "data");
      installReleaseDir(appDir, pionBin, readerBin, runnerBin, true);
      mkdirSync(join(dataDir, "mesh"), { recursive: true });
      const idRes = spawnSync(pionBin, ["id", "--data", dataDir], { encoding: "utf8" });
      assert.equal(idRes.status, 0, idRes.stderr);
      const stationId = idRes.stdout.trim();

      stageR8Restore(dataDir);
      writeFileSync(join(dataDir, "config.json"), JSON.stringify({ engine: "pion", connects: [] }));
      writeFileSync(
        join(dataDir, "mesh", "cloud.json"),
        JSON.stringify({
          origin: `http://127.0.0.1:${cloudPort}`,
          workspace: ws,
          workspace_name: "R8RestWS",
          station: stationId,
          name: "r11-locked-db",
          peers: [{ id: peerId, name: "peer-r8", relay: null }],
          relay_urls: [],
          grant_keys: grantKeys,
        }),
      );

      const dbPath = join(dataDir, "stillfail.db");
      const seed = new DatabaseSync(dbPath);
      seed.exec("PRAGMA journal_mode = DELETE;");
      seed.exec("CREATE TABLE threads (id INTEGER PRIMARY KEY); CREATE TABLE sessions (key TEXT PRIMARY KEY);");
      seed.close();
      const origBytes = readFileSync(dbPath);

      const locker = new DatabaseSync(dbPath);
      locker.exec("PRAGMA locking_mode = EXCLUSIVE; BEGIN EXCLUSIVE");
      const out: string[] = [];
      const child = spawn(pionBin, ["run", "--app", appDir, "--data", dataDir, "--port", "0"], {
        env: { ...process.env, STILLFAIL_NO_DISCOVERY: "1", STILLFAIL_NO_DHT: "1" },
        stdio: ["ignore", "pipe", "pipe"],
      });
      child.stdout.on("data", (d) => out.push(String(d)));
      child.stderr.on("data", (d) => out.push(String(d)));
      const code = await new Promise<number | null>((resolve) => child.on("exit", (c) => resolve(c)));
      try { locker.exec("ROLLBACK; PRAGMA locking_mode = NORMAL"); } catch {}
      try { locker.close(); } catch {}

      assert.equal(code, 1, `6c-locked-existing-db must exit 1, got ${code}: ${out.join("")}`);
      assert.ok(
        out.join("").includes("target db not ready for restore handoff"),
        `6c-locked-existing-db expected restore handoff refusal stderr, got: ${out.join("")}`,
      );
      assert.equal(existsSync(join(dataDir, "restore", "ready.json")), true, "6c-locked-existing-db must preserve restore/ready.json");
      assert.equal(existsSync(join(dataDir, "restore", "copy")), true, "6c-locked-existing-db must preserve restore/copy");
      assert.equal(Buffer.compare(readFileSync(dbPath), origBytes), 0, "6c-locked-existing-db must not modify locked DB bytes");
      const verify = new DatabaseSync(dbPath);
      const jm = (verify.prepare("PRAGMA journal_mode").get() as { journal_mode: string }).journal_mode;
      verify.close();
      assert.equal(jm.toLowerCase(), "delete", "6c-locked-existing-db must preserve journal_mode=delete");
    }

    // (6d-io-fail-atomic-retry) Astra R10 P1: Empty 0-table DB (`PRAGMA user_version = 13`) + real
    // SQLite write failure (`RLIMIT_FSIZE` with `SIGXFSZ` ignored) during atomic temp-DB init ->
    // Pion exits 1, leaves `stillfail.db` untouched with 0 tables and zero `.init.*.tmp` debris,
    // preserves `<data>/restore/` -> clearing the limit and booting real Launcher in same dir
    // atomically initializes schema, `exec_replace`s into Node, restores `s:r8-rem` + `thread_sessions`,
    // and persists first peer `connect.event` edit!
    {
      const dir = freshDir("ext-gate-r11-io-retry");
      const appDir = join(dir, "app");
      const dataDir = join(dir, "data");
      installReleaseDir(appDir, pionBin, readerBin, runnerBin, true);
      mkdirSync(join(dataDir, "mesh"), { recursive: true });
      const idRes = spawnSync(pionBin, ["id", "--data", dataDir], { encoding: "utf8" });
      assert.equal(idRes.status, 0, idRes.stderr);
      const stationId = idRes.stdout.trim();

      stageR8Restore(dataDir);
      writeFileSync(join(dataDir, "config.json"), JSON.stringify({ engine: "pion", connects: [] }));
      writeFileSync(
        join(dataDir, "mesh", "cloud.json"),
        JSON.stringify({
          origin: `http://127.0.0.1:${cloudPort}`,
          workspace: ws,
          workspace_name: "R8RestWS",
          station: stationId,
          name: "r11-io-retry",
          peers: [{ id: peerId, name: "peer-r8", relay: null }],
          relay_urls: [],
          grant_keys: grantKeys,
        }),
      );

      // Seed a valid 0-table SQLite file with `PRAGMA user_version = 13`.
      const dbPath = join(dataDir, "stillfail.db");
      const emptyDb = new DatabaseSync(dbPath);
      emptyDb.exec("PRAGMA user_version = 13;");
      emptyDb.close();

      // 1. Trigger real mid-migration SQLite write failures at RLIMIT_FSIZE=155648 (304*512B)
      //    and RLIMIT_FSIZE=229376 (448*512B) with `SIGXFSZ` ignored so SQLite observes `EFBIG`
      //    inside `ensure_restore_target_schema`'s single `BEGIN IMMEDIATE` transaction and rolls back cleanly.
      for (const fsizeBlocks of [304, 448]) {
        const failRun = spawnSync(
          "sh",
          ["-c", `trap "" XFSZ; ulimit -f ${fsizeBlocks}; exec "$@"`, "--", pionBin, "run", "--app", appDir, "--data", dataDir, "--port", "0"],
          {
            env: { ...process.env, STILLFAIL_NO_DISCOVERY: "1", STILLFAIL_NO_DHT: "1" },
            encoding: "utf8",
            timeout: 15_000,
          },
        );
        assert.equal(failRun.status, 1, `6d-io-fail-atomic-retry must exit 1 under ulimit -f ${fsizeBlocks}, got ${failRun.status}: ${failRun.stdout}\n${failRun.stderr}`);
        assert.ok(
          `${failRun.stdout}\n${failRun.stderr}`.includes("target db not ready for restore handoff"),
          `6d-io-fail-atomic-retry expected restore handoff refusal stderr under ulimit -f ${fsizeBlocks}, got: ${failRun.stdout}\n${failRun.stderr}`,
        );
        assert.equal(existsSync(join(dataDir, "restore", "ready.json")), true, "restore/ready.json MUST be preserved on mid-init IO failure");
        assert.equal(existsSync(join(dataDir, "restore", "copy")), true, "restore/copy MUST be preserved on mid-init IO failure");
        const checkZero = new DatabaseSync(dbPath, { readOnly: true });
        const tblCount = (checkZero.prepare("SELECT COUNT(*) AS n FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'").get() as { n: number }).n;
        checkZero.close();
        assert.equal(tblCount, 0, `stillfail.db MUST remain 0-table after rollback under ulimit -f ${fsizeBlocks}`);
      }

      // 2. Lift fault (same dataDir, same 0-table `stillfail.db`, NO re-staging!) and boot via real Launcher.
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

      await until(
        "6d-io-fail-atomic-retry exec_replace into Node after lifting RLIMIT_FSIZE",
        () => logs.join("").includes("external connects active (restore:pending-ready-json); exec-replacing into Node station"),
        20_000,
      );
      const nodePid = await until(
        "6d-io-fail-atomic-retry Node pid serving /healthz 200",
        async () => {
          const p = readHubPid(dataDir);
          const port = readPorts(dataDir).admin ?? 0;
          if (p > 0 && isAlive(p) && port > 0) {
            try {
              const r = await httpCall(port, "GET", "/healthz");
              if (r.status === 200) return p;
            } catch {}
          }
          return null;
        },
        25_000,
      );
      assert.equal(isAlive(nodePid), true);
      await until(
        "6d-io-fail-atomic-retry Node replica restore completed",
        () => (existsSync(join(dataDir, "replica", "restored.json")) ? true : null),
        15_000,
      );
      const restoredOut = JSON.parse(readFileSync(join(dataDir, "replica", "restored.json"), "utf8"));
      assert.equal(restoredOut.error, null, `6d-io-fail-atomic-retry restored.json must have error === null, got: ${JSON.stringify(restoredOut)}`);

      const editedText = "edited-after-6d-atomic-retry";
      const evResp = await until("6d-io-fail-atomic-retry connect.event edit on Node", async () => {
        try {
          return await peerRpc(peerEp, stationId, `127.0.0.1:${udpPort}`, ws, {
            method: "connect.event",
            workspace: ws,
            connect: { id: "slack-r8", origin: peerId },
            described: describedR8,
            event: {
              type: "changed",
              channel: "C_R8",
              threadTs: "200.001",
              ts: "200.001",
              text: editedText,
            },
          });
        } catch {
          return null;
        }
      }, 15_000);
      assert.deepEqual(evResp.result, { ok: true });

      launcher.kill("SIGTERM");
      await until("6d-io-fail-atomic-retry launcher exit", () => launcher.exitCode !== null || launcher.signalCode !== null);

      const verifyStore = Store.open(dbPath, join(dataDir, "archives"));
      const sessRow = verifyStore.getSession("s:r8-rem");
      assert.ok(sessRow !== null && sessRow.connect === remoteConnectId, "6d-io-fail-atomic-retry expected restored cross-station session s:r8-rem");
      const tsCount = (verifyStore.db.prepare("SELECT COUNT(*) AS n FROM thread_sessions").get() as { n: number }).n;
      assert.equal(tsCount, 1, "6d-io-fail-atomic-retry expected thread_sessions === 1");
      const origRows = verifyStore.db
        .prepare("SELECT text FROM entries WHERE text LIKE ?")
        .all("%before-r8-restore%") as { text: string }[];
      const turnRow = verifyStore.db
        .prepare("SELECT outcome FROM turns WHERE id = ?")
        .get("r11-saved-turn") as { outcome: string } | undefined;
      const editedRows = verifyStore.db
        .prepare("SELECT text FROM entries WHERE text LIKE ?")
        .all(`%${editedText}%`) as { text: string }[];
      verifyStore.close();
      assert.ok(origRows.length >= 1, "6d-io-fail-atomic-retry expected original restored message in stillfail.db");
      assert.equal(turnRow?.outcome, "completed", "6d-io-fail-atomic-retry expected restored turn r11-saved-turn");
      assert.ok(editedRows.length >= 1, "6d-io-fail-atomic-retry expected edited text persisted in stillfail.db");
    }

    // (6e-higher-user-version) Astra R10: Higher `user_version` (e.g. 99) -> Pion MUST exit 1,
    // zero writes to `stillfail.db`, and preserve `<data>/restore/`!
    {
      const dir = freshDir("ext-gate-r11-higher-uv");
      const appDir = join(dir, "app");
      const dataDir = join(dir, "data");
      installReleaseDir(appDir, pionBin, readerBin, runnerBin, true);
      mkdirSync(join(dataDir, "mesh"), { recursive: true });
      const idRes = spawnSync(pionBin, ["id", "--data", dataDir], { encoding: "utf8" });
      assert.equal(idRes.status, 0, idRes.stderr);
      const stationId = idRes.stdout.trim();

      stageR8Restore(dataDir);
      writeFileSync(join(dataDir, "config.json"), JSON.stringify({ engine: "pion", connects: [] }));
      writeFileSync(
        join(dataDir, "mesh", "cloud.json"),
        JSON.stringify({
          origin: `http://127.0.0.1:${cloudPort}`,
          workspace: ws,
          workspace_name: "R8RestWS",
          station: stationId,
          name: "r11-higher-uv",
          peers: [{ id: peerId, name: "peer-r8", relay: null }],
          relay_urls: [],
          grant_keys: grantKeys,
        }),
      );

      const dbPath = join(dataDir, "stillfail.db");
      const futureDb = new DatabaseSync(dbPath);
      futureDb.exec("PRAGMA user_version = 99;");
      futureDb.close();
      const origBytes = readFileSync(dbPath);

      const res = spawnSync(pionBin, ["run", "--app", appDir, "--data", dataDir, "--port", "0"], {
        env: { ...process.env, STILLFAIL_NO_DISCOVERY: "1", STILLFAIL_NO_DHT: "1" },
        encoding: "utf8",
        timeout: 15_000,
      });
      assert.equal(res.status, 1, `6e-higher-user-version must exit 1, got ${res.status}: ${res.stdout}\n${res.stderr}`);
      assert.ok(
        `${res.stdout}\n${res.stderr}`.includes("unsupported_user_version:99"),
        `6e-higher-user-version expected unsupported_user_version:99, got: ${res.stdout}\n${res.stderr}`,
      );
      assert.equal(Buffer.compare(readFileSync(dbPath), origBytes), 0, "6e-higher-user-version must not modify DB bytes");
      assert.equal(existsSync(join(dataDir, "restore", "ready.json")), true, "6e-higher-user-version must preserve restore/ready.json");
      assert.equal(existsSync(join(dataDir, "restore", "copy")), true, "6e-higher-user-version must preserve restore/copy");
    }

    // (6f-concurrent-writer-preserves-commit) Astra R11 P1 #1: On an empty v13 WAL DB, another SQLite
    // connection holds a write transaction creating `threads` and inserting local thread 73.
    // Because `ensure_restore_target_schema` coordinates via SQLite `BEGIN IMMEDIATE` in-place (zero
    // rename/inode swap), BOTH timings preserve inode and thread 73 on the canonical `stillfail.db` path!
    {
      const setupWalV13 = (tag: string) => {
        const dir = freshDir(tag);
        const appDir = join(dir, "app");
        const dataDir = join(dir, "data");
        installReleaseDir(appDir, pionBin, readerBin, runnerBin, true);
        mkdirSync(join(dataDir, "mesh"), { recursive: true });
        const idRes = spawnSync(pionBin, ["id", "--data", dataDir], { encoding: "utf8" });
        assert.equal(idRes.status, 0, idRes.stderr);
        const stationId = idRes.stdout.trim();
        stageR8Restore(dataDir);
        writeFileSync(join(dataDir, "config.json"), JSON.stringify({ engine: "pion", connects: [] }));
        writeFileSync(
          join(dataDir, "mesh", "cloud.json"),
          JSON.stringify({
            origin: `http://127.0.0.1:${cloudPort}`,
            workspace: ws,
            workspace_name: "R8RestWS",
            station: stationId,
            name: tag,
            peers: [{ id: peerId, name: "peer-r8", relay: null }],
            relay_urls: [],
            grant_keys: grantKeys,
          }),
        );
        const dbPath = join(dataDir, "stillfail.db");
        const initDb = new DatabaseSync(dbPath);
        initDb.exec("PRAGMA journal_mode = WAL; PRAGMA user_version = 13;");
        initDb.close();
        return { appDir, dataDir, dbPath, inoBefore: statSync(dbPath).ino };
      };

      const createThreadsSql =
        "CREATE TABLE threads (id INTEGER PRIMARY KEY, surface TEXT NOT NULL, channel TEXT NOT NULL, thread_ts TEXT NOT NULL, title TEXT, auto_title TEXT, created_by TEXT, created_at INTEGER NOT NULL, home TEXT, hidden_at INTEGER, hidden_by TEXT, shown_at INTEGER, project TEXT, project_locked INTEGER NOT NULL DEFAULT 0, tags TEXT, UNIQUE(surface, channel, thread_ts));";

      // (a) Concurrent writer commits after 300ms (inside busy_timeout=2000) while real Launcher starts:
      {
        const { appDir, dataDir, dbPath, inoBefore } = setupWalV13("ext-gate-r12-conc-300ms");
        const writer = new DatabaseSync(dbPath);
        writer.exec(`BEGIN IMMEDIATE; ${createThreadsSql} INSERT INTO threads (id, surface, channel, thread_ts, title, created_at) VALUES (73, 'web', 'CHAT', '73.000', 'LocalThread73', ${Date.now()});`);
        const commitTimer = setTimeout(() => {
          try { writer.exec("COMMIT"); } catch {}
          try { writer.close(); } catch {}
        }, 300);

        const udpPort = await pickFreeUdpPort();
        const launcher = spawn(launcherBin, ["run", "--app", appDir, "--data", dataDir, "--port", "0"], {
          env: {
            ...process.env,
            STILLFAIL_NO_DISCOVERY: "1",
            STILLFAIL_NO_DHT: "1",
            STILLFAIL_MESH_BIND_ADDR: `127.0.0.1:${udpPort}`,
            STILLFAIL_READER_ENGINE: "mb",
          },
          stdio: "ignore",
        });
        children.push(launcher);
        await until("6f-a Node serving /healthz 200", async () => {
          const p = readHubPid(dataDir);
          const port = readPorts(dataDir).admin ?? 0;
          if (p > 0 && isAlive(p) && port > 0) {
            try {
              const r = await httpCall(port, "GET", "/healthz");
              if (r.status === 200) return p;
            } catch {}
          }
          return null;
        }, 25_000);
        clearTimeout(commitTimer);
        try { writer.close(); } catch {}
        launcher.kill("SIGTERM");
        await until("6f-a launcher exit", () => launcher.exitCode !== null || launcher.signalCode !== null);

        assert.equal(statSync(dbPath).ino, inoBefore, "6f-a stillfail.db inode MUST NOT change");
        const ro = new DatabaseSync(dbPath, { readOnly: true });
        const row = ro.prepare("SELECT id, title FROM threads WHERE id = 73").get() as { id: number; title: string } | undefined;
        ro.close();
        assert.deepEqual(row ? { ...row } : null, { id: 73, title: "LocalThread73" }, "6f-a local thread 73 MUST survive concurrent restore handoff");
      }

      // (b) Concurrent writer holds lock >2000ms (3.5s) -> Pion exits 1 preserving restore/ -> writer commits:
      {
        const { appDir, dataDir, dbPath, inoBefore } = setupWalV13("ext-gate-r12-conc-3500ms");
        const writer = new DatabaseSync(dbPath);
        writer.exec(`BEGIN IMMEDIATE; ${createThreadsSql} INSERT INTO threads (id, surface, channel, thread_ts, title, created_at) VALUES (73, 'web', 'CHAT', '73.000', 'LocalThread73Long', ${Date.now()});`);
        const out: string[] = [];
        const child = spawn(pionBin, ["run", "--app", appDir, "--data", dataDir, "--port", "0"], {
          env: { ...process.env, STILLFAIL_NO_DISCOVERY: "1", STILLFAIL_NO_DHT: "1" },
          stdio: ["ignore", "pipe", "pipe"],
        });
        child.stdout.on("data", (d) => out.push(String(d)));
        child.stderr.on("data", (d) => out.push(String(d)));
        const code = await new Promise<number | null>((resolve) => child.on("exit", (c) => resolve(c)));
        writer.exec("COMMIT");
        writer.close();

        assert.equal(code, 1, `6f-b must exit 1 on >2000ms writer lock, got ${code}: ${out.join("")}`);
        assert.equal(existsSync(join(dataDir, "restore", "ready.json")), true, "6f-b must preserve restore/ready.json");
        assert.equal(existsSync(join(dataDir, "restore", "copy")), true, "6f-b must preserve restore/copy");
        assert.equal(statSync(dbPath).ino, inoBefore, "6f-b stillfail.db inode MUST NOT change");
        const ro = new DatabaseSync(dbPath, { readOnly: true });
        const row = ro.prepare("SELECT id, title FROM threads WHERE id = 73").get() as { id: number; title: string } | undefined;
        ro.close();
        assert.deepEqual(row ? { ...row } : null, { id: 73, title: "LocalThread73Long" }, "6f-b local thread 73 MUST survive after writer commits");
      }
    }

    // (6g-partial-4-core-tables-restores-turns) Astra R11 P1 #2: Residual v13 DB with ONLY the 4 core
    // tables (`threads`, `sessions`, `entries`, `thread_sessions`, missing `turns`/`letters`) + snapshot
    // containing completed `turns` row (`r11-saved-turn`) -> Pion completes all 17 restorable tables inside
    // `BEGIN IMMEDIATE` before `exec_replace` -> Node restores `r11-saved-turn` (`completed`) and cleans `restore/`!
    {
      const dir = freshDir("ext-gate-r12-partial-4tbl");
      const appDir = join(dir, "app");
      const dataDir = join(dir, "data");
      installReleaseDir(appDir, pionBin, readerBin, runnerBin, true);
      mkdirSync(join(dataDir, "mesh"), { recursive: true });
      const idRes = spawnSync(pionBin, ["id", "--data", dataDir], { encoding: "utf8" });
      assert.equal(idRes.status, 0, idRes.stderr);
      const stationId = idRes.stdout.trim();

      stageR8Restore(dataDir);
      writeFileSync(join(dataDir, "config.json"), JSON.stringify({ engine: "pion", connects: [] }));
      writeFileSync(
        join(dataDir, "mesh", "cloud.json"),
        JSON.stringify({
          origin: `http://127.0.0.1:${cloudPort}`,
          workspace: ws,
          workspace_name: "R8RestWS",
          station: stationId,
          name: "r12-partial-4tbl",
          peers: [{ id: peerId, name: "peer-r8", relay: null }],
          relay_urls: [],
          grant_keys: grantKeys,
        }),
      );

      // Build a real v13 DB and drop every table except the 4 core tables.
      const dbPath = join(dataDir, "stillfail.db");
      Store.open(dbPath, join(dataDir, "archives")).close();
      const partial = new DatabaseSync(dbPath);
      const keep = new Set(["threads", "sessions", "entries", "thread_sessions"]);
      const views = partial.prepare("SELECT name FROM sqlite_master WHERE type='view'").all() as { name: string }[];
      for (const v of views) partial.exec(`DROP VIEW IF EXISTS "${v.name}";`);
      const triggers = partial.prepare("SELECT name FROM sqlite_master WHERE type='trigger'").all() as { name: string }[];
      for (const tr of triggers) partial.exec(`DROP TRIGGER IF EXISTS "${tr.name}";`);
      const tables = partial
        .prepare("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")
        .all() as { name: string }[];
      for (const t of tables) {
        if (!keep.has(t.name)) partial.exec(`DROP TABLE IF EXISTS "${t.name}";`);
      }
      partial.close();

      const udpPort = await pickFreeUdpPort();
      const launcher = spawn(launcherBin, ["run", "--app", appDir, "--data", dataDir, "--port", "0"], {
        env: {
          ...process.env,
          STILLFAIL_NO_DISCOVERY: "1",
          STILLFAIL_NO_DHT: "1",
          STILLFAIL_MESH_BIND_ADDR: `127.0.0.1:${udpPort}`,
          STILLFAIL_READER_ENGINE: "mb",
        },
        stdio: "ignore",
      });
      children.push(launcher);
      await until(
        "6g Node replica restore completed",
        () => (existsSync(join(dataDir, "replica", "restored.json")) ? true : null),
        25_000,
      );
      const restoredOut = JSON.parse(readFileSync(join(dataDir, "replica", "restored.json"), "utf8"));
      assert.equal(restoredOut.error, null, `6g restored.json must have error === null, got: ${JSON.stringify(restoredOut)}`);
      assert.equal(existsSync(join(dataDir, "restore")), false, "6g restore/ must be cleaned after full restore");

      launcher.kill("SIGTERM");
      await until("6g launcher exit", () => launcher.exitCode !== null || launcher.signalCode !== null);

      const verifyStore = Store.open(dbPath, join(dataDir, "archives"));
      const turnRow = verifyStore.db
        .prepare("SELECT outcome FROM turns WHERE id = ?")
        .get("r11-saved-turn") as { outcome: string } | undefined;
      const tsCount = (verifyStore.db.prepare("SELECT COUNT(*) AS n FROM thread_sessions").get() as { n: number }).n;
      const origRows = verifyStore.db
        .prepare("SELECT text FROM entries WHERE text LIKE ?")
        .all("%before-r8-restore%") as { text: string }[];
      verifyStore.close();
      assert.equal(turnRow?.outcome, "completed", "6g MUST restore completed turn r11-saved-turn");
      assert.equal(tsCount, 1, "6g expected thread_sessions === 1");
      assert.ok(origRows.length >= 1, "6g expected original restored message");
    }

    // (6h-zero-byte-and-missing-db-preserve-wal) Astra R11 P1 #3: Both missing DB + real >10KB WAL
    // AND 0-byte DB + real >10KB WAL MUST exit 1 before touching SQLite, leaving WAL and restore/
    // SHA-256 byte-for-byte identical (and 0-byte DB still 0 bytes)!
    {
      // Create a genuine >10 KiB WAL file from a real SQLite WAL database.
      const walSeedDir = freshDir("ext-gate-r12-wal-seed");
      const walSeedPath = join(walSeedDir, "seed.db");
      const walSeed = new DatabaseSync(walSeedPath);
      walSeed.exec("PRAGMA journal_mode = WAL; PRAGMA wal_autocheckpoint = 0; CREATE TABLE payload (id INTEGER PRIMARY KEY, body TEXT);");
      const ins = walSeed.prepare("INSERT INTO payload (body) VALUES (?)");
      for (let i = 0; i < 40; i++) ins.run("W".repeat(512));
      const realWalBytes = readFileSync(`${walSeedPath}-wal`);
      walSeed.close();
      assert.ok(realWalBytes.length > 10_000, `expected >10KB real WAL, got ${realWalBytes.length}`);
      const sha256 = (buf: Buffer) => createHash("sha256").update(buf).digest("hex");
      const expectedWalHash = sha256(realWalBytes);

      for (const mode of ["missing-db", "zero-byte-db"] as const) {
        const dir = freshDir(`ext-gate-r12-wal-${mode}`);
        const appDir = join(dir, "app");
        const dataDir = join(dir, "data");
        installReleaseDir(appDir, pionBin, readerBin, runnerBin, true);
        mkdirSync(join(dataDir, "mesh"), { recursive: true });
        const idRes = spawnSync(pionBin, ["id", "--data", dataDir], { encoding: "utf8" });
        assert.equal(idRes.status, 0, idRes.stderr);
        const stationId = idRes.stdout.trim();
        stageR8Restore(dataDir);
        writeFileSync(join(dataDir, "config.json"), JSON.stringify({ engine: "pion", connects: [] }));
        writeFileSync(
          join(dataDir, "mesh", "cloud.json"),
          JSON.stringify({
            origin: `http://127.0.0.1:${cloudPort}`,
            workspace: ws,
            workspace_name: "R8RestWS",
            station: stationId,
            name: `r12-wal-${mode}`,
            peers: [{ id: peerId, name: "peer-r8", relay: null }],
            relay_urls: [],
            grant_keys: grantKeys,
          }),
        );
        const dbPath = join(dataDir, "stillfail.db");
        const walPath = `${dbPath}-wal`;
        if (mode === "zero-byte-db") writeFileSync(dbPath, "");
        writeFileSync(walPath, realWalBytes);
        const readyHashBefore = sha256(readFileSync(join(dataDir, "restore", "ready.json")));

        const res = spawnSync(pionBin, ["run", "--app", appDir, "--data", dataDir, "--port", "0"], {
          env: { ...process.env, STILLFAIL_NO_DISCOVERY: "1", STILLFAIL_NO_DHT: "1" },
          encoding: "utf8",
          timeout: 15_000,
        });
        assert.equal(res.status, 1, `6h-${mode} must exit 1, got ${res.status}: ${res.stdout}\n${res.stderr}`);
        assert.equal(sha256(readFileSync(walPath)), expectedWalHash, `6h-${mode} WAL SHA-256 MUST be untouched`);
        assert.equal(
          sha256(readFileSync(join(dataDir, "restore", "ready.json"))),
          readyHashBefore,
          `6h-${mode} restore/ready.json SHA-256 MUST be untouched`,
        );
        assert.equal(existsSync(join(dataDir, "restore", "copy")), true, `6h-${mode} restore/copy MUST be preserved`);
        if (mode === "zero-byte-db") {
          assert.equal(statSync(dbPath).size, 0, "6h-zero-byte-db must remain 0 bytes");
        } else {
          assert.equal(existsSync(dbPath), false, "6h-missing-db must remain absent");
        }
      }
    }

    // (6i-historical-v13-adds-missing-columns) Astra R12 #1: Historical v13 target DB that already has
    // all 17 restorable tables EXCEPT newer columns (specifically `proposal_outcomes.info_op_id`) +
    // snapshot carrying an unsynced accepted proposal with `info_op_id` -> Pion runs idempotent
    // `run_v13_migrations` inside `BEGIN IMMEDIATE` before `exec_replace` -> Node restores full row
    // and `Store.getUnsyncedAcceptOutcome(1, 1)` returns the exact `opId`!
    {
      const dir = freshDir("ext-gate-r13-hist-v13");
      const appDir = join(dir, "app");
      const dataDir = join(dir, "data");
      installReleaseDir(appDir, pionBin, readerBin, runnerBin, true);
      mkdirSync(join(dataDir, "mesh"), { recursive: true });
      const idRes = spawnSync(pionBin, ["id", "--data", dataDir], { encoding: "utf8" });
      assert.equal(idRes.status, 0, idRes.stderr);
      const stationId = idRes.stdout.trim();

      stageR8Restore(dataDir);
      writeFileSync(join(dataDir, "config.json"), JSON.stringify({ engine: "pion", connects: [] }));
      writeFileSync(
        join(dataDir, "mesh", "cloud.json"),
        JSON.stringify({
          origin: `http://127.0.0.1:${cloudPort}`,
          workspace: ws,
          workspace_name: "R8RestWS",
          station: stationId,
          name: "r13-hist-v13",
          peers: [{ id: peerId, name: "peer-r8", relay: null }],
          relay_urls: [],
          grant_keys: grantKeys,
        }),
      );

      // Build a real v13 DB with all 17 tables, then recreate `proposal_outcomes` WITHOUT `info_op_id`.
      const dbPath = join(dataDir, "stillfail.db");
      Store.open(dbPath, join(dataDir, "archive")).close();
      const hist = new DatabaseSync(dbPath);
      hist.exec(
        "DROP TABLE proposal_outcomes; CREATE TABLE proposal_outcomes (thread INTEGER NOT NULL, n INTEGER NOT NULL, status TEXT NOT NULL, project TEXT, resolved_by TEXT NOT NULL, resolved_at INTEGER NOT NULL, info_note TEXT, info_refs TEXT, info_synced INTEGER NOT NULL DEFAULT 1, PRIMARY KEY (thread, n));",
      );
      hist.close();

      const udpPort = await pickFreeUdpPort();
      const launcher = spawn(launcherBin, ["run", "--app", appDir, "--data", dataDir, "--port", "0"], {
        env: {
          ...process.env,
          STILLFAIL_NO_DISCOVERY: "1",
          STILLFAIL_NO_DHT: "1",
          STILLFAIL_MESH_BIND_ADDR: `127.0.0.1:${udpPort}`,
          STILLFAIL_READER_ENGINE: "mb",
        },
        stdio: "ignore",
      });
      children.push(launcher);
      await until(
        "6i Node replica restore completed",
        () => (existsSync(join(dataDir, "replica", "restored.json")) ? true : null),
        25_000,
      );
      const restoredOut = JSON.parse(readFileSync(join(dataDir, "replica", "restored.json"), "utf8"));
      assert.equal(restoredOut.error, null, `6i restored.json must have error === null, got: ${JSON.stringify(restoredOut)}`);
      assert.equal(existsSync(join(dataDir, "restore")), false, "6i restore/ must be cleaned");

      launcher.kill("SIGTERM");
      await until("6i launcher exit", () => launcher.exitCode !== null || launcher.signalCode !== null);

      const verifyStore = Store.open(dbPath, join(dataDir, "archive"));
      const outcome = verifyStore.getUnsyncedAcceptOutcome(1, 1);
      verifyStore.close();
      assert.ok(outcome !== null, "6i MUST preserve proposal_outcomes.info_op_id so getUnsyncedAcceptOutcome(1, 1) is non-null");
      assert.equal(outcome.opId, r13OpId, "6i opId must match snapshot UUID");
      assert.equal(outcome.project, "ProjR13");
    }

    // (6j-v12-archive-cold-restore-upgrades-to-v13) Astra R12 #2 & Opus R12 nit: Real v12 data dir
    // with archived thread 73 (`<data>/archive/threads/73.jsonl.zst`) + staged merge snapshot ->
    // default `engine=pion` cold start leaves v12 DB untouched (0 writes) and hands off to Node ->
    // Node upgrades v12->v13 AND merges snapshot so both archived local message and remote snapshot
    // message are readable; also confirms v14 still refuses with exit 1!
    {
      const dir = freshDir("ext-gate-r13-v12-upgrade");
      const appDir = join(dir, "app");
      const dataDir = join(dir, "data");
      installReleaseDir(appDir, pionBin, readerBin, runnerBin, true);
      mkdirSync(join(dataDir, "mesh"), { recursive: true });
      const idRes = spawnSync(pionBin, ["id", "--data", dataDir], { encoding: "utf8" });
      assert.equal(idRes.status, 0, idRes.stderr);
      const stationId = idRes.stdout.trim();

      stageR8Restore(dataDir, true);
      writeFileSync(join(dataDir, "config.json"), JSON.stringify({ engine: "pion", connects: [] }));
      writeFileSync(
        join(dataDir, "mesh", "cloud.json"),
        JSON.stringify({
          origin: `http://127.0.0.1:${cloudPort}`,
          workspace: ws,
          workspace_name: "R8RestWS",
          station: stationId,
          name: "r13-v12-upgrade",
          peers: [{ id: peerId, name: "peer-r8", relay: null }],
          relay_urls: [],
          grant_keys: grantKeys,
        }),
      );

      const dbPath = join(dataDir, "stillfail.db");
      const archiveDir = join(dataDir, "archive");
      Store.open(dbPath, archiveDir).close();
      const v12 = new DatabaseSync(dbPath);
      v12.exec(`INSERT INTO threads (id, surface, channel, thread_ts, title, created_at, archived_at) VALUES (73, 'web', 'CHAT', '73.v12', 'ArchivedV12Thread', ${nowMs}, ${nowMs});`);
      v12.exec("PRAGMA user_version = 12;");
      v12.close();
      writeCompressed(
        threadFile(archiveDir, 73),
        JSON.stringify({
          thread: 73,
          n: 1,
          kind: "message",
          target: null,
          ts: "73.001",
          authorKind: "person",
          author: "alice@example.com",
          text: "v12-archived-local-73",
          attachments: [],
          quotes: [],
          declared: null,
          at: nowMs,
        }) + "\n",
      );

      const udpPort = await pickFreeUdpPort();
      const launcher = spawn(launcherBin, ["run", "--app", appDir, "--data", dataDir, "--port", "0"], {
        env: {
          ...process.env,
          STILLFAIL_NO_DISCOVERY: "1",
          STILLFAIL_NO_DHT: "1",
          STILLFAIL_MESH_BIND_ADDR: `127.0.0.1:${udpPort}`,
          STILLFAIL_READER_ENGINE: "mb",
        },
        stdio: "ignore",
      });
      children.push(launcher);
      await until(
        "6j Node v12 upgrade & replica merge completed",
        () => (existsSync(join(dataDir, "replica", "restored.json")) ? true : null),
        25_000,
      );
      const restoredOut = JSON.parse(readFileSync(join(dataDir, "replica", "restored.json"), "utf8"));
      assert.equal(restoredOut.error, null, `6j restored.json must have error === null, got: ${JSON.stringify(restoredOut)}`);
      assert.equal(existsSync(join(dataDir, "restore")), false, "6j restore/ must be cleaned");

      launcher.kill("SIGTERM");
      await until("6j launcher exit", () => launcher.exitCode !== null || launcher.signalCode !== null);

      const checkV13 = new DatabaseSync(dbPath, { readOnly: true });
      const finalVer = (checkV13.prepare("PRAGMA user_version").get() as { user_version: number }).user_version;
      const localRows = checkV13.prepare("SELECT text FROM entries WHERE text LIKE '%v12-archived-local-73%'").all() as { text: string }[];
      const remoteRows = checkV13.prepare("SELECT text FROM entries WHERE text LIKE '%before-r8-restore%'").all() as { text: string }[];
      checkV13.close();
      assert.equal(finalVer, 13, "6j v12 DB MUST be upgraded to user_version === 13 by Node");
      assert.ok(localRows.length >= 1, "6j MUST restore archived local v12 thread 73 entries");
      assert.ok(remoteRows.length >= 1, "6j MUST merge remote snapshot entries");

      // Also verify v14 (SCHEMA_VERSION + 1) still refuses with exit 1 and preserves restore/.
      const dir14 = freshDir("ext-gate-r13-v14-refuse");
      const appDir14 = join(dir14, "app");
      const dataDir14 = join(dir14, "data");
      installReleaseDir(appDir14, pionBin, readerBin, runnerBin, true);
      mkdirSync(join(dataDir14, "mesh"), { recursive: true });
      stageR8Restore(dataDir14);
      writeFileSync(join(dataDir14, "config.json"), JSON.stringify({ engine: "pion", connects: [] }));
      const db14Path = join(dataDir14, "stillfail.db");
      const db14 = new DatabaseSync(db14Path);
      db14.exec("PRAGMA user_version = 14;");
      db14.close();
      const res14 = spawnSync(pionBin, ["run", "--app", appDir14, "--data", dataDir14, "--port", "0"], {
        env: { ...process.env, STILLFAIL_NO_DISCOVERY: "1", STILLFAIL_NO_DHT: "1" },
        encoding: "utf8",
        timeout: 15_000,
      });
      assert.equal(res14.status, 1, `v14 must refuse with exit 1, got ${res14.status}`);
      assert.ok(`${res14.stdout}\n${res14.stderr}`.includes("unsupported_user_version:14"));
      assert.equal(existsSync(join(dataDir14, "restore", "ready.json")), true);
    }

    // Schema version parity guard (Opus R11 nit): `station_store/src/schema.pion` SCHEMA_VERSION === TS SCHEMA_VERSION.
    {
      const pionSchemaSrc = readFileSync(
        join(root, "pion", "station-main", "packages", "station_store", "src", "schema.pion"),
        "utf8",
      );
      const m = pionSchemaSrc.match(/pub let SCHEMA_VERSION\s*:\s*Int\s*=\s*(\d+)/);
      assert.ok(m, "expected SCHEMA_VERSION constant in station_store/src/schema.pion");
      assert.equal(Number(m[1]), SCHEMA_VERSION, "Pion station_store SCHEMA_VERSION must match TS SCHEMA_VERSION");
    }
  }

  // --- Scenario 7 (Astra R6 P1 #2): 3-state `DbDepCheck` under 850ms & >2000ms exclusive SQLite lock + clean control DB ---
  {
    const lockDir = freshDir("ext-gate-r7-dblock");
    mkdirSync(join(lockDir, "mesh"), { recursive: true });
    const idRes = spawnSync(pionBin, ["id", "--data", lockDir], { encoding: "utf8" });
    assert.equal(idRes.status, 0, idRes.stderr);
    const lockId = idRes.stdout.trim();
    writeFileSync(join(lockDir, "config.json"), JSON.stringify({ engine: "pion", connects: [] }));
    writeFileSync(
      join(lockDir, "mesh", "cloud.json"),
      JSON.stringify({
        workspace: "ws-dblock",
        workspace_name: "DbLockWS",
        station: lockId,
        name: "dblock-station",
        peers: [],
        relay_urls: [],
        grant_keys: grantKeys,
      }),
    );

    const lockDbPath = join(lockDir, "stillfail.db");
    const s = Store.open(lockDbPath, join(lockDir, "archives"));
    const nowMs = Date.now();
    s.db
      .prepare(
        "INSERT INTO sessions (key, connect, scope, title, runtime, profile, workspace, token, created_at, last_active_at, cwd, ws) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
      )
      .run("s:lock-1", "ext@peer-lock", "s:lock-1", "LockSess", "claude", "default", lockDir, randomBytes(32).toString("hex"), nowMs, nowMs, lockDir, "ws-dblock");
    s.close();

    // (a) 850ms exclusive lock (locking_mode=EXCLUSIVE blocks even WAL readers) -> Pion waits inside busy_timeout=2000, sees Found, exits 1!
    {
      const locker = new DatabaseSync(lockDbPath);
      locker.exec("PRAGMA locking_mode = EXCLUSIVE; BEGIN EXCLUSIVE");
      const timer = setTimeout(() => {
        try { locker.exec("ROLLBACK; PRAGMA locking_mode = NORMAL"); } catch {}
        try { locker.close(); } catch {}
      }, 850);
      const out: string[] = [];
      const child = spawn(pionBin, ["run", "--data", lockDir, "--port", "0"], {
        env: { ...process.env, STILLFAIL_NO_DISCOVERY: "1", STILLFAIL_NO_DHT: "1", STILLFAIL_STATION_ENGINE_STRICT: "1" },
        stdio: ["ignore", "pipe", "pipe"],
      });
      child.stdout.on("data", (d) => out.push(String(d)));
      child.stderr.on("data", (d) => out.push(String(d)));
      const code = await new Promise<number | null>((resolve) => child.on("exit", (c) => resolve(c)));
      clearTimeout(timer);
      try { locker.close(); } catch {}
      assert.equal(code, 1, `850ms lock must exit 1, got ${code}: ${out.join("")}`);
      assert.ok(out.join("").includes("db:remote-connect-sessions"), `expected db:remote-connect-sessions, got: ${out.join("")}`);
    }

    // (b) Sustained >2000ms exclusive lock -> Pion hits SQLITE_BUSY -> Unknown -> fail-safe exits 1!
    {
      const locker = new DatabaseSync(lockDbPath);
      locker.exec("PRAGMA locking_mode = EXCLUSIVE; BEGIN EXCLUSIVE");
      const out: string[] = [];
      const child = spawn(pionBin, ["run", "--data", lockDir, "--port", "0"], {
        env: { ...process.env, STILLFAIL_NO_DISCOVERY: "1", STILLFAIL_NO_DHT: "1", STILLFAIL_STATION_ENGINE_STRICT: "1" },
        stdio: ["ignore", "pipe", "pipe"],
      });
      child.stdout.on("data", (d) => out.push(String(d)));
      child.stderr.on("data", (d) => out.push(String(d)));
      const code = await new Promise<number | null>((resolve) => child.on("exit", (c) => resolve(c)));
      try { locker.exec("ROLLBACK; PRAGMA locking_mode = NORMAL"); } catch {}
      try { locker.close(); } catch {}
      assert.equal(code, 1, `>2000ms lock must fail-safe exit 1, got ${code}: ${out.join("")}`);
      assert.ok(
        out.join("").includes("sqlite_master_err:") || out.join("").includes("db:unreadable:"),
        `expected Unknown SQLite lock refusal, got: ${out.join("")}`,
      );
    }

    // (c) Control DB with NO cross-station session -> Pion boots cleanly under STRICT=1!
    {
      const ctrlDir = freshDir("ext-gate-r7-dbctrl");
      mkdirSync(join(ctrlDir, "mesh"), { recursive: true });
      const cidRes = spawnSync(pionBin, ["id", "--data", ctrlDir], { encoding: "utf8" });
      assert.equal(cidRes.status, 0, cidRes.stderr);
      const ctrlId = cidRes.stdout.trim();
      writeFileSync(join(ctrlDir, "config.json"), JSON.stringify({ engine: "pion", connects: [] }));
      writeFileSync(
        join(ctrlDir, "mesh", "cloud.json"),
        JSON.stringify({
          workspace: "ws-dbctrl",
          workspace_name: "DbCtrlWS",
          station: ctrlId,
          name: "dbctrl-station",
          peers: [],
          relay_urls: [],
          grant_keys: grantKeys,
        }),
      );
      const cs = Store.open(join(ctrlDir, "stillfail.db"), join(ctrlDir, "archives"));
      cs.close();

      const ctrlUdp = await pickFreeUdpPort();
      const ctrlProc = spawn(pionBin, ["run", "--data", ctrlDir, "--port", "0"], {
        env: {
          ...process.env,
          STILLFAIL_NO_DISCOVERY: "1",
          STILLFAIL_NO_DHT: "1",
          STILLFAIL_MESH_BIND_ADDR: `127.0.0.1:${ctrlUdp}`,
          STILLFAIL_STATION_ENGINE_STRICT: "1",
        },
        stdio: "ignore",
      });
      children.push(ctrlProc);
      const ctrlPort = await until("Scenario 7c control DB Pion loopback port", () => {
        const p = readPorts(ctrlDir).admin ?? 0;
        return p > 0 ? p : null;
      }, 15_000);
      assert.equal((await httpCall(ctrlPort, "GET", "/healthz")).status, 200);
      ctrlProc.kill("SIGTERM");
      await until("Scenario 7c control DB Pion exit", () => ctrlProc.exitCode !== null || ctrlProc.signalCode !== null);
    }
  }

  // --- Scenario 8 (Astra R6 P2): Case-insensitive `STILLFAIL_STATION_ENGINE_STRICT` (`True` & `TrUe`) ---
  {
    const ciDir = freshDir("ext-gate-r7-strict-case");
    mkdirSync(join(ciDir, "mesh"), { recursive: true });
    const idRes = spawnSync(pionBin, ["id", "--data", ciDir], { encoding: "utf8" });
    assert.equal(idRes.status, 0, idRes.stderr);
    const ciId = idRes.stdout.trim();
    writeFileSync(
      join(ciDir, "config.json"),
      JSON.stringify({ engine: "pion", connects: [{ id: "sl-ci", kind: "slack" }] }),
    );
    writeFileSync(
      join(ciDir, "mesh", "cloud.json"),
      JSON.stringify({
        workspace: "ws-ci",
        workspace_name: "CiWS",
        station: ciId,
        name: "ci-station",
        peers: [],
        relay_urls: [],
        grant_keys: grantKeys,
      }),
    );
    for (const strictVal of ["True", "TrUe"]) {
      const r = spawnSync(pionBin, ["run", "--data", ciDir, "--port", "0"], {
        env: { ...process.env, STILLFAIL_NO_DISCOVERY: "1", STILLFAIL_NO_DHT: "1", STILLFAIL_STATION_ENGINE_STRICT: strictVal },
        encoding: "utf8",
        timeout: 15_000,
      });
      assert.equal(r.status, 1, `STRICT=${strictVal} must exit 1, got ${r.status}`);
      assert.ok(
        `${r.stdout}\n${r.stderr}`.includes("slack:sl-ci"),
        `STRICT=${strictVal} refusal must mention slack:sl-ci`,
      );
      assert.equal(existsSync(join(ciDir, "stillfail.db")), false, `STRICT=${strictVal} must not create stillfail.db`);
    }
  }
});

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
      env: { ...process.env, STILLFAIL_NO_DISCOVERY: "1",
          STILLFAIL_PION_NATIVE_CONNECTS_TEST: "1", STILLFAIL_NO_DHT: "1", STILLFAIL_MESH_BIND_ADDR: `127.0.0.1:${udpPort}` },
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
      env: { ...process.env, STILLFAIL_NO_DISCOVERY: "1",
          STILLFAIL_PION_NATIVE_CONNECTS_TEST: "1", STILLFAIL_NO_DHT: "1", STILLFAIL_MESH_BIND_ADDR: `127.0.0.1:${udpPort}` },
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
      env: { ...process.env, STILLFAIL_NO_DISCOVERY: "1",
          STILLFAIL_PION_NATIVE_CONNECTS_TEST: "1", STILLFAIL_NO_DHT: "1", STILLFAIL_MESH_BIND_ADDR: `127.0.0.1:${udpPort}` },
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

    // (b) P0-A: Clean Pion whole station WITHOUT `STILLFAIL_PION_NATIVE_CONNECTS_TEST=1` MUST reject
    // runtime `connect.event` with zero DB/remote-connects writes (never false-ACK into black hole).
    const dir = freshDir("w17b5-p0a-runtime-gate");
    const appDir = join(dir, "app");
    const dataDir = join(dir, "data");
    installReleaseDir(appDir, pionBin, readerBin, runnerBin, false);
    mkdirSync(join(dataDir, "mesh"), { recursive: true });
    const idRes = spawnSync(pionBin, ["id", "--data", dataDir], { encoding: "utf8" });
    assert.equal(idRes.status, 0, idRes.stderr);
    const stationId = idRes.stdout.trim();
    const peerEp = await bindClientEp(mesh);
    const peerId = peerEp.id();
    const ws = "ws-p0a-gate";
    writeFileSync(join(dataDir, "config.json"), JSON.stringify({ engine: "pion", connects: [] }));
    writeFileSync(
      join(dataDir, "mesh", "cloud.json"),
      JSON.stringify({
        workspace: ws,
        workspace_name: "P0AGateWS",
        station: stationId,
        name: "p0a-gate-station",
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
    await until("P0-A gate station ready", async () => {
      const p = readHubPid(dataDir);
      const port = readPorts(dataDir).admin ?? 0;
      if (p > 0 && isAlive(p) && port > 0 && readProcCmdline(p).includes("stillfail-station-pion")) {
        try {
          if ((await httpCall(port, "GET", "/healthz")).status === 200) return p;
        } catch {}
      }
      return null;
    }, 20_000);
    const gateResp = await until("P0-A connect.event rejected", async () => {
      try {
        return await peerRpc(peerEp, stationId, `127.0.0.1:${udpPort}`, ws, {
          method: "connect.event",
          workspace: ws,
          connect: { id: "slack-peer", origin: peerId },
          described: { kind: "slack", workspace: ws, mode: "per-thread", requireMention: true, bind: { runtime: "claude" } },
          event: { type: "message", message: { channel: "C1", threadTs: "1.1", ts: "1.1", user: "U1", text: "should be rejected", addressed: true } },
        });
      } catch (err: any) {
        const msg = String(err?.message ?? err);
        if (msg.includes("native connects disabled")) return { error: msg };
        return null;
      }
    }, 15_000);
    assert.ok(
      typeof gateResp?.error === "string" && gateResp.error.includes("native connects disabled until runner cutover"),
      `P0-A expected rejection error, got: ${JSON.stringify(gateResp)}`,
    );
    assert.equal(existsSync(join(dataDir, "remote-connects.json")), false, "P0-A must not write remote-connects.json");
    launcher.kill("SIGTERM");
    await until("P0-A launcher exit", () => launcher.exitCode !== null || launcher.signalCode !== null);
    const checkDb = new DatabaseSync(join(dataDir, "stillfail.db"), { open: true, readOnly: true });
    const sessCnt = (checkDb.prepare("SELECT COUNT(*) AS n FROM sessions").get() as { n: number }).n;
    const entryCnt = (checkDb.prepare("SELECT COUNT(*) AS n FROM entries").get() as { n: number }).n;
    checkDb.close();
    assert.equal(sessCnt, 0, "P0-A must create zero sessions");
    assert.equal(entryCnt, 0, "P0-A must insert zero entries");
  }
});
