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
import { generateKeyPairSync, randomBytes, sign as cryptoSign } from "node:crypto";
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
import { PEER_HTTP_ALPN } from "../src/mesh/peer-http.ts";
import { ALPN as ADMIN_ALPN } from "../src/mesh/serve.ts";
import { Reader, writeLine } from "../src/mesh/wire.ts";
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
    return "";
  }
}

function readProcCmdline(pid: number): string {
  try {
    return readFileSync(`/proc/${pid}/cmdline`, "utf8").replace(/\0/g, " ").trim();
  } catch {
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
    "stillfail-station-pion 0.1.0 roles:rig,whole commands:id,status,lock,channel,enroll,update,heap,admin",
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

test("W17A.6: Real before_store restore/ready.json recovery (Node Exporter -> Pion) + corrupt ready.json fail-closed", async () => {
  const mesh = resolveMeshAddon();
  const { grantKeys, signMemberJwt } = makeGrantKeysAndSigner();

  // --- Part A: Export a real snapshot from a Node Store and restore it on Pion startup ---
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

  const destDir = freshDir("replica-dest");
  const appDir = join(destDir, "app");
  const dataDir = join(destDir, "data");
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
      name: "restore-station",
      peers: [],
      relay_urls: [],
      grant_keys: grantKeys,
    }),
  );

  // Stage `<data>/restore/copy/<gen>`, `<data>/restore/copy/files`, and `<data>/restore/ready.json`.
  const copyDir = join(dataDir, "restore", "copy");
  mkdirSync(copyDir, { recursive: true });
  cpSync(genPath, join(copyDir, head.gen), { recursive: true });
  cpSync(filesSrcDir, join(copyDir, "files"), { recursive: true });
  writeFileSync(
    join(dataDir, "restore", "ready.json"),
    JSON.stringify({ origin: originId, workspace: ws, gen: head.gen, name: "src-laptop", from: "peer-1" }),
  );
  // Pre-create empty schema DB as Node/Pion fresh restore expects (or let restore build it).
  assert.equal(existsSync(join(dataDir, "stillfail.db")), false);

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

  await until("restored pion pid", () => {
    const p = readHubPid(dataDir);
    return p > 0 && isAlive(p) ? p : null;
  });

  // Verify `ready.json` was consumed, `replica/restored.json` has `error: null`, and `chat:a` is visible!
  const restoredJson = await until("replica/restored.json written", () => {
    const p = join(dataDir, "replica", "restored.json");
    if (!existsSync(p)) return null;
    try {
      return JSON.parse(readFileSync(p, "utf8")) as { error: unknown };
    } catch {
      return null;
    }
  });
  assert.equal(restoredJson.error, null, `unexpected restore error: ${JSON.stringify(restoredJson)}`);
  assert.equal(existsSync(join(dataDir, "restore", "ready.json")), false, "ready.json should be consumed after restore");

  const clientEp = await bindClientEp(mesh);
  const jwt = signMemberJwt({
    ws,
    device: clientEp.id(),
    sub: "u-rest",
    email: "alice@example.com",
    name: "Alice",
    role: "owner",
  });
  const { conn } = await until("restore admin connect", () =>
    openAdminConn(clientEp, stationId, `127.0.0.1:${udpPort}`, jwt),
  );
  const chatsResp = await adminRequest(conn, "GET", "/chats");
  assert.equal(chatsResp.status, 200, chatsResp.body.toString("utf8"));
  assert.ok(chatsResp.body.toString("utf8").includes("RestoredFromNode"), `restored chat missing: ${chatsResp.body.toString("utf8")}`);
  conn.close(0, "done");

  launcher.kill("SIGTERM");
  await until("restore launcher exit", () => launcher.exitCode !== null || launcher.signalCode !== null);

  // --- Part B: Corrupt `restore/ready.json` MUST fail closed, NOT create empty DB, and preserve `ready.json` ---
  const badDir = freshDir("replica-corrupt");
  mkdirSync(join(badDir, "restore"), { recursive: true });
  mkdirSync(join(badDir, "mesh"), { recursive: true });
  writeFileSync(join(badDir, "config.json"), JSON.stringify({ engine: "pion" }));
  const badReady = join(badDir, "restore", "ready.json");
  writeFileSync(badReady, "{not-valid-json");

  const badRun = spawnSync(pionBin, ["run", "--data", badDir, "--port", "0"], {
    env: { ...process.env, STILLFAIL_NO_DISCOVERY: "1", STILLFAIL_NO_DHT: "1" },
    encoding: "utf8",
    timeout: 15_000,
  });
  assert.notEqual(badRun.status, 0, "corrupt ready.json must exit non-zero");
  assert.equal(existsSync(badReady), true, "corrupt ready.json must be preserved");
  assert.equal(readFileSync(badReady, "utf8"), "{not-valid-json");
  assert.equal(existsSync(join(badDir, "stillfail.db")), false, "corrupt ready.json must NOT create empty stillfail.db");
});

test("W17A.7: ConnectsOsRuntime nested Slack config + real DB-before-ACK + SIGUSR2 handover & clean shutdown", async () => {
  const { grantKeys } = makeGrantKeysAndSigner();

  // Local mock Slack HTTP (`apps.connections.open`) + Socket Mode WS server.
  let wsConnections = 0;
  const ackedEnvelopes: string[] = [];
  const dbRowsAtAck: number[] = [];
  let dataDirRef = "";

  const slackSrv = createHttpServer((req, res) => {
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
      wsConnections++;
      const connNum = wsConnections;
      ws.send(JSON.stringify({ type: "hello", num_connections: connNum }));
      ws.on("message", (raw) => {
        try {
          const msg = JSON.parse(String(raw));
          if (typeof msg.envelope_id === "string") {
            ackedEnvelopes.push(msg.envelope_id);
            // At the exact moment ACK arrives, verify the row is ALREADY persisted in SQLite!
            if (dataDirRef && existsSync(join(dataDirRef, "stillfail.db"))) {
              const db = new DatabaseSync(join(dataDirRef, "stillfail.db"), { readOnly: true });
              const row = db
                .prepare("SELECT COUNT(*) AS cnt FROM entries WHERE text = 'hello-slack-db-before-ack'")
                .get() as { cnt: number };
              db.close();
              dbRowsAtAck.push(row.cnt);
            }
          }
        } catch {}
      });
      if (connNum === 1) {
        ws.send(
          JSON.stringify({
            envelope_id: "env-w17a-slack-1",
            type: "events_api",
            payload: {
              event: {
                type: "app_mention",
                channel: "C_W17A",
                ts: "1795780000.000100",
                thread_ts: "1795780000.000100",
                user: "U_ALICE",
                text: "hello-slack-db-before-ack",
              },
            },
          }),
        );
      }
    });
  });
  await new Promise<void>((resolve) => slackSrv.listen(0, "127.0.0.1", () => resolve()));
  const slackPort = (slackSrv.address() as AddressInfo).port;

  const dir = freshDir("slack-connect");
  const appDir = join(dir, "app");
  const dataDir = join(dir, "data");
  dataDirRef = dataDir;
  installReleaseDir(appDir, pionBin, readerBin, runnerBin, false);
  mkdirSync(join(dataDir, "mesh"), { recursive: true });

  const idRes = spawnSync(pionBin, ["id", "--data", dataDir], { encoding: "utf8" });
  assert.equal(idRes.status, 0, idRes.stderr);
  const stationId = idRes.stdout.trim();

  // Real Node nested `config.json` schema: omitted `kind` MUST default to `"slack"`, omitted `enabled` to `true`!
  writeFileSync(
    join(dataDir, "config.json"),
    JSON.stringify({
      engine: "pion",
      connects: [
        {
          id: "slack-main",
          bind: { runtime: "claude" },
          slack: {
            appToken: "xapp-1-w17a-test",
            botToken: "xoxb-w17a-test",
            baseUrl: `http://127.0.0.1:${slackPort}`,
          },
        },
      ],
    }),
  );
  writeFileSync(
    join(dataDir, "mesh", "cloud.json"),
    JSON.stringify({
      workspace: "ws-slack",
      workspace_name: "SlackWS",
      station: stationId,
      name: "slack-station",
      peers: [],
      relay_urls: [],
      grant_keys: grantKeys,
    }),
  );

  const udpPort = await pickFreeUdpPort();
  const slackLogs: string[] = [];
  const launcher = spawn(launcherBin, ["run", "--app", appDir, "--data", dataDir, "--port", "0"], {
    env: {
      ...process.env,
      STILLFAIL_NO_DISCOVERY: "1",
      STILLFAIL_NO_DHT: "1",
      STILLFAIL_MESH_BIND_ADDR: `127.0.0.1:${udpPort}`,
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  children.push(launcher);
  launcher.stdout.on("data", (d) => slackLogs.push(String(d)));
  launcher.stderr.on("data", (d) => slackLogs.push(String(d)));

  const pid1 = await until("slack pion pid1", () => {
    const p = readHubPid(dataDir);
    return p > 0 && isAlive(p) ? p : null;
  });

  // Verify Slack Socket Mode connected, persisted message to `stillfail.db` BEFORE sending ACK!
  try {
    await until("slack envelope ACK received", () => ackedEnvelopes.includes("env-w17a-slack-1"), 8_000);
  } catch (e) {
    const logPath = join(dataDir, "stillfail.log");
    const logTail = existsSync(logPath) ? readFileSync(logPath, "utf8").slice(-1000) : "(no stillfail.log)";
    throw new Error(`${(e as Error).message} | wsConnections=${wsConnections} | slackLogs=${slackLogs.join("").slice(-300)} | stillfail.log=${logTail}`);
  }
  assert.ok(dbRowsAtAck.length >= 1 && dbRowsAtAck[0] >= 1, `DB row was NOT persisted before Slack ACK: ${JSON.stringify(dbRowsAtAck)}`);

  // Trigger `SIGUSR2` handover while Slack connector is live -> old Pion exits cleanly, new Pion reconnects!
  const fdBefore = openFdCount(pid1);
  launcher.kill("SIGUSR2");
  const pid2 = await until("slack pion pid2 after SIGUSR2", () => {
    const p = readHubPid(dataDir);
    return p > 0 && p !== pid1 && isAlive(p) ? p : null;
  });
  await until("old pion pid1 exited after handover", () => !isAlive(pid1), 10_000);
  await until("new pion reconnected to mock Slack WS", () => wsConnections >= 2, 15_000);
  const fdAfter = openFdCount(pid2);
  if (fdBefore > 0 && fdAfter > 0) {
    assert.ok(Math.abs(fdAfter - fdBefore) <= 12, `unexpected FD delta across handover: before=${fdBefore} after=${fdAfter}`);
  }

  // Graceful `SIGTERM` shutdown: launcher + pion exit cleanly with zero orphans!
  launcher.kill("SIGTERM");
  await until("slack launcher exit", () => launcher.exitCode !== null || launcher.signalCode !== null);
  await until("slack pion pid2 exited", () => !isAlive(pid2));
});
