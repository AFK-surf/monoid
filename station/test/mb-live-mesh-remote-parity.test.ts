// Wave 2 Track B: Mesh / Peers / Remote tasks & files / Dirsync / peer_forward / xshare / Safe-mode lock parity
// on two real pure-MoonBit stations (`stillfail-reader run`) connected over local loopback iroh mesh, under a PATH
// containing no Node.
import assert from "node:assert/strict";
import { type ChildProcess, spawn, spawnSync } from "node:child_process";
import { createHash, generateKeyPairSync, randomBytes, sign as nodeSign, type KeyObject } from "node:crypto";
import { createSocket } from "node:dgram";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { createServer as httpServer, request as httpRequest } from "node:http";
import { type AddressInfo, connect as tcpConnect, createServer as tcpServer, type Server, type Socket } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { after, test } from "node:test";
import { WebSocketServer, type WebSocket } from "ws";
import { type Entry, endpointBytes, entryHash, signedBytes as lockSignedBytes } from "../src/cloud/lock.ts";
import { loadMesh, type Connection, type Stream as MeshStream } from "../src/mesh/native.ts";
import { Reader } from "../src/mesh/wire.ts";
import { mbReaderBinary } from "../src/read/mb-reader.ts";
import { Store } from "../src/store/store.ts";
import { GrantKey } from "./fake-control-plane.ts";

const binary = mbReaderBinary();
const addon = (() => {
  try {
    return loadMesh();
  } catch {
    return null;
  }
})();
const skip =
  binary === null
    ? "the MoonBit program (stillfail-reader) is not built here"
    : addon === null
      ? "the mesh addon is not built here (scripts/native.ts run mesh)"
      : process.platform === "win32"
        ? "the launcher's descriptors are Unix's"
        : false;

const dirs: string[] = [];
const fresh = (what: string) => {
  const dir = mkdtempSync(join(tmpdir(), `sfm-${what}-`));
  dirs.push(dir);
  return dir;
};

const children: ChildProcess[] = [];
const cleanups: (() => void | Promise<void>)[] = [];
after(async () => {
  for (const fn of cleanups.splice(0).reverse()) {
    try {
      await fn();
    } catch {
      // best effort cleanup
    }
  }
  const left = children.filter((c) => c.exitCode === null && c.signalCode === null);
  for (const c of left) c.kill("SIGKILL");
  await Promise.all(
    left.map((c) =>
      c.exitCode === null && c.signalCode === null ? new Promise<void>((r) => c.once("exit", () => r())) : undefined,
    ),
  );
  for (const d of dirs) rmSync(d, { recursive: true, force: true });
});

const TOOLS = [
  "sh", "ps", "mv", "cat", "curl", "sleep", "echo", "printf", "env", "python3",
  "git", "ls", "find", "sort", "rm", "mkdir", "cp", "dirname", "basename",
  "sed", "tr", "head", "wc", "uname", "dd", "lsof",
];

function binOf(name: string): string {
  const search = [
    ...(process.env.PATH ?? "").split(":").filter((d) => d !== ""),
    "/usr/bin", "/bin", "/usr/sbin", "/sbin", "/usr/local/bin", "/opt/homebrew/bin",
  ];
  for (const d of search) {
    const at = join(d, name);
    if (existsSync(at)) return at;
  }
  return "";
}

function toolsPath(): string {
  const dir = fresh("path");
  for (const t of TOOLS) {
    const found = binOf(t);
    if (found !== "" && !found.includes("node")) symlinkSync(found, join(dir, t));
  }
  assert.equal(existsSync(join(dir, "node")), false);
  return dir;
}

const noNode = (more: Record<string, string> = {}) => ({
  PATH: toolsPath(),
  HOME: process.env.HOME ?? tmpdir(),
  TMPDIR: tmpdir(),
  ...more,
});

async function given<T>(
  what: string,
  f: () => T | null | undefined | false | Promise<T | null | undefined | false>,
  ms = 25_000,
): Promise<T> {
  const until = Date.now() + ms;
  let last: unknown = null;
  for (;;) {
    try {
      const v = await f();
      if (v !== null && v !== undefined && v !== false) return v as T;
    } catch (e) {
      last = e;
    }
    if (Date.now() > until) {
      throw new Error(`never came (${ms}ms): ${what}${last ? ` (${(last as Error).message})` : ""}`);
    }
    await new Promise((r) => setTimeout(r, 50));
  }
}

const readJson = (p: string) => (existsSync(p) ? JSON.parse(readFileSync(p, "utf8")) : null);
const sha256 = (b: Buffer) => createHash("sha256").update(b).digest("hex");

function alive(pid: number, group = false): boolean {
  try {
    process.kill(group ? -pid : pid, 0);
    return true;
  } catch {
    return false;
  }
}

async function freeUdpPort(): Promise<number> {
  const socket = createSocket("udp4");
  await new Promise<void>((r) => socket.bind(0, "127.0.0.1", () => r()));
  const port = socket.address().port;
  await new Promise<void>((r) => socket.close(() => r()));
  return port;
}

async function freeTcpPort(): Promise<number> {
  const s = tcpServer();
  await new Promise<void>((r) => s.listen(0, "127.0.0.1", () => r()));
  const port = (s.address() as AddressInfo).port;
  await new Promise<void>((r) => s.close(() => r()));
  return port;
}

function stationId(data: string): string {
  const r = spawnSync(binary!, ["id", "--data", data], { env: noNode(), encoding: "utf8" });
  assert.equal(r.status, 0, r.stderr);
  return r.stdout.trim();
}

type ControlPlaneState = {
  workspace: string;
  workspace_name: string;
  name: string;
  peers: unknown[];
  grant_keys?: unknown;
  revocations?: unknown[];
  workspaces?: unknown[];
  relay_urls?: string[];
};

async function controlPlane(stateFor: (stationId: string) => ControlPlaneState) {
  const sockets: { station: string; socket: WebSocket; said: string[] }[] = [];
  const server = httpServer((_req, res) => {
    res.writeHead(200, { "content-type": "application/json" }).end("{}");
  });
  const wss = new WebSocketServer({ noServer: true });
  server.on("upgrade", (req, socket, head) => {
    if (!req.url?.startsWith("/v1/stations/connect")) return void socket.destroy();
    const st = String(req.headers["x-stillfail-station"] ?? "");
    wss.handleUpgrade(req, socket, head, (ws) => {
      const entry = { station: st, socket: ws, said: [] as string[] };
      sockets.push(entry);
      ws.on("message", (m) => {
        const text = String(m);
        entry.said.push(text);
        if (text === "ping") ws.send("pong");
      });
      const s = stateFor(st);
      ws.send(JSON.stringify({ type: "state", relay_urls: [], revocations: [], ...s }));
    });
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", () => r()));
  cleanups.push(() => {
    for (const s of sockets) s.socket.terminate();
    wss.close();
    server.close();
  });
  return {
    origin: `http://127.0.0.1:${(server.address() as AddressInfo).port}`,
    sockets,
    push(station: string, frame: unknown) {
      for (const s of sockets) {
        if (s.station === station && s.socket.readyState === 1) s.socket.send(JSON.stringify(frame));
      }
    },
  };
}

type Launched = {
  child: ChildProcess;
  said: any[];
  next: (what: string, ok: (m: any) => boolean) => Promise<any>;
  tell: (m: unknown) => void;
  ended: Promise<number | null>;
  err: () => string;
  stop: () => Promise<void>;
};

async function launch(data: string, app: string, env: Record<string, string>): Promise<Launched> {
  const listener = () =>
    new Promise<Server>((resolve) => {
      const s = tcpServer();
      s.listen(0, "127.0.0.1", () => resolve(s));
    });
  const [mcpSrv, loopSrv] = [await listener(), await listener()];
  const fd = (s: Server) => (s as any)._handle.fd as number;
  const child = spawn(
    binary!,
    ["run", "--app", app, "--data", data, "--launcher-fds", "3,4,5", "--launcher-carries", "--launcher-heartbeat"],
    {
      stdio: ["ignore", "pipe", "pipe", fd(mcpSrv), fd(loopSrv), "pipe"],
      env: noNode({ STILLFAIL_HELD_EVERY_MS: "300", ...env }),
    },
  );
  children.push(child);
  mcpSrv.close();
  loopSrv.close();
  const said: any[] = [];
  const waiters: (() => void)[] = [];
  const channel = (child.stdio as readonly unknown[])[5] as Socket;
  createInterface({ input: channel }).on("line", (line) => {
    said.push(JSON.parse(line));
    for (const w of waiters.splice(0)) w();
  });
  let err = "";
  child.stderr!.on("data", (d) => (err += d));
  const next = (what: string, ok: (m: any) => boolean) =>
    new Promise<any>((resolve, reject) => {
      const timer = setTimeout(
        () => reject(new Error(`never said: ${what}; said ${JSON.stringify(said)}; stderr ${err}`)),
        20_000,
      );
      const look = () => {
        const found = said.find(ok);
        if (found !== undefined) {
          clearTimeout(timer);
          resolve(found);
        } else waiters.push(look);
      };
      look();
    });
  const ended = new Promise<number | null>((resolve) => child.on("exit", (code) => resolve(code)));
  const tell = (m: unknown) => channel.write(`${JSON.stringify(m)}\n`);
  const stop = async () => {
    if (child.exitCode === null && child.signalCode === null) {
      tell({ op: "stop" });
      assert.equal(await ended, 0, err);
    }
  };
  return { child, said, next, tell, ended, err: () => err, stop };
}

function httpRaw(
  port: number,
  path: string,
  o: { method?: string; body?: string | Buffer; headers?: Record<string, string> } = {},
): Promise<{ status: number; headers: Record<string, unknown>; body: Buffer }> {
  return new Promise((resolve, reject) => {
    const headers: Record<string, string> = { ...(o.headers ?? {}) };
    if (o.body !== undefined && !Object.keys(headers).some((k) => k.toLowerCase() === "content-type")) {
      headers["content-type"] = "application/json";
    }
    const req = httpRequest(
      {
        host: "127.0.0.1",
        port,
        path,
        method: o.method ?? (o.body === undefined ? "GET" : "POST"),
        headers,
        agent: false,
      },
      (res) => {
        const parts: Buffer[] = [];
        res.on("data", (d: Buffer) => parts.push(d));
        res.on("end", () => resolve({ status: res.statusCode ?? 0, headers: res.headers, body: Buffer.concat(parts) }));
      },
    );
    req.on("error", reject);
    req.end(o.body);
  });
}

async function mcp(port: number, token: string, method: string, params: unknown = {}): Promise<any> {
  const r = await httpRaw(port, "/mcp", {
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
    headers: { authorization: `Bearer ${token}` },
  });
  assert.equal(r.status, 200, r.body.toString());
  return JSON.parse(r.body.toString());
}

async function tool(port: number, token: string, name: string, args: unknown = {}): Promise<{ text: string; error: boolean }> {
  const said = await mcp(port, token, "tools/call", { name, arguments: args });
  assert.equal(said.error, undefined, JSON.stringify(said));
  return { text: said.result.content[0].text, error: said.result.isError === true };
}

const line = (stream: MeshStream, value: unknown) => stream.write(Buffer.from(JSON.stringify(value) + "\n"));

async function member(conn: Connection, credential: string, lock?: { device: string; proof: string }) {
  const first = await conn.openBi();
  await line(first, { credential, protocol: 2, ...(lock ? { lock } : {}) });
  return new Reader(first).line();
}

async function memberAsk(conn: Connection, method: string, path: string, body?: unknown): Promise<[number, any]> {
  const stream = await conn.openBi();
  await line(stream, { method, path, headers: { "content-type": "application/json" } });
  if (body !== undefined) await stream.write(Buffer.from(JSON.stringify(body)));
  await stream.finish();
  const reader = new Reader(stream);
  const head = await reader.line();
  return [head.status, JSON.parse((await reader.rest()).toString() || "null")];
}

const hexOf = (k: KeyObject) => Buffer.from(k.export({ format: "jwk" }).x as string, "base64url").toString("hex");
function ed() {
  const { privateKey, publicKey } = generateKeyPairSync("ed25519");
  const hex = hexOf(publicKey);
  return { hex, id: `ed25519:${hex}`, sign: (bytes: Buffer) => nodeSign(null, bytes, privateKey).toString("hex") };
}
type EdKey = ReturnType<typeof ed>;
const signLockEntry = (e: Omit<Entry, "sig">, key: EdKey): Entry => ({
  ...e,
  sig: { key: key.id, alg: "Ed25519", sig: key.sign(lockSignedBytes(entryHash(e as Entry))) },
});

async function startPair(opts: {
  wsA?: string;
  wsB?: string;
  wsNameA?: string;
  wsNameB?: string;
  bridgeWs?: string;
  grant?: GrantKey;
  build?: string;
} = {}) {
  const wsA = opts.wsA ?? "w1";
  const wsB = opts.wsB ?? wsA;
  const wsNameA = opts.wsNameA ?? "Team";
  const wsNameB = opts.wsNameB ?? wsNameA;
  const [dataA, dataB, app] = [fresh("sta"), fresh("stb"), fresh("app")];
  writeFileSync(join(app, "BUILD"), `${opts.build ?? "9520"}\n`);
  const [idA, idB] = [stationId(dataA), stationId(dataB)];
  const [portA, portB] = [await freeUdpPort(), await freeUdpPort()];
  const sameWs = wsA === wsB;
  const peerA = { id: idA, name: "alpha", ips: [`127.0.0.1:${portA}`] };
  const peerB = { id: idB, name: "beta", ips: [`127.0.0.1:${portB}`] };
  const grantKeys = opts.grant ? { keys: [opts.grant.jwk] } : null;

  const stateFor = (st: string): ControlPlaneState => {
    const isA = st === idA;
    if (sameWs) {
      return {
        workspace: wsA,
        workspace_name: wsNameA,
        name: isA ? "alpha" : "beta",
        peers: [peerA, peerB],
        grant_keys: grantKeys,
      };
    }
    return {
      workspace: isA ? wsA : wsB,
      workspace_name: isA ? wsNameA : wsNameB,
      name: isA ? "alpha" : "beta",
      peers: [isA ? peerA : peerB],
      grant_keys: grantKeys,
      ...(opts.bridgeWs
        ? {
            workspaces: [
              {
                workspace: opts.bridgeWs,
                workspace_name: "Bridge",
                name: isA ? "alpha" : "beta",
                peers: [peerA, peerB],
                revocations: [],
              },
            ],
          }
        : {}),
    };
  };

  const plane = await controlPlane(stateFor);
  for (const [data, id, isA] of [
    [dataA, idA, true],
    [dataB, idB, false],
  ] as const) {
    mkdirSync(join(data, "mesh"), { recursive: true });
    const s = stateFor(id);
    writeFileSync(
      join(data, "mesh", "cloud.json"),
      JSON.stringify({
        origin: plane.origin,
        station: id,
        workspace: s.workspace,
        workspace_name: s.workspace_name,
        name: s.name,
        relay_url: "",
        relay_urls: [],
        grant_keys: grantKeys,
        peers: s.peers,
        revocations: [],
        ...(opts.bridgeWs
          ? {
              joined: [
                {
                  workspace: opts.bridgeWs,
                  workspace_name: "Bridge",
                  name: isA ? "alpha" : "beta",
                  peers: [peerA, peerB],
                  revocations: [],
                  grant_keys: grantKeys,
                },
              ],
            }
          : {}),
      }),
    );
  }

  const env = (port: number) => ({
    STILLFAIL_LOCAL_ADMIN: "1",
    STILLFAIL_NO_DISCOVERY: "1",
    STILLFAIL_MESH_BIND_ADDR: `127.0.0.1:${port}`,
  });
  const [a, b] = [await launch(dataA, app, env(portA)), await launch(dataB, app, env(portB))];
  await a.next("alpha ready", (m) => m.ready === true);
  await b.next("beta ready", (m) => m.ready === true);
  const doorA = (await a.next("alpha mcp", (m) => m.serving === "mcp")).port as number;
  const doorB = (await b.next("beta mcp", (m) => m.serving === "mcp")).port as number;
  for (const d of [dataA, dataB]) {
    await given("online at control plane", () => readJson(join(d, "run", "presence.json"))?.online === true);
  }
  return {
    plane, dataA, dataB, app, idA, idB, portA, portB, doorA, doorB, a, b,
    stop: async () => {
      await a.stop();
      await b.stop();
    },
  };
}

// ── 1. Mesh discovery (`station_list`) & `/peer/` door gate ─────────────────────────────────────────────────────────
test("mesh discovery (station_list) and /peer/ door gate reject spoofed Host/Origin, bad targets, and unauthorized peers", { skip }, async () => {
  const pair = await startPair({ build: "9521" });
  const workA = fresh("workA");
  const storeA = Store.open(join(pair.dataA, "stillfail.db"), join(pair.dataA, "archive"), {
    currentTimeMillisUnsafe: () => Date.now(),
  } as never);
  storeA.insertSession({
    key: "s1", connect: "ember", runtime: "claude", profile: "cc", workspace: workA,
    token: "t1", createdAt: Date.now(), lastActiveAt: Date.now(),
  });
  storeA.close();

  // Station A discovers Station B via MCP `station_list` (whole list + single station detail).
  const listed = await given("station_list sees beta with load", async () => {
    const r = await tool(pair.doorA, "t1", "station_list", {});
    if (r.error) return null;
    const parsed = JSON.parse(r.text);
    const beta = (parsed.stations ?? []).find((s: any) => s.id === pair.idB);
    return beta && typeof beta.load === "string" && beta.load.length > 0 ? parsed : null;
  });
  const alpha = listed.stations.find((s: any) => s.id === pair.idA);
  const beta = listed.stations.find((s: any) => s.id === pair.idB);
  assert.ok(alpha && alpha.here === true, JSON.stringify(listed));
  assert.equal(beta.name, "beta");
  assert.equal(beta.version, "0.1.9521");
  assert.match(beta.load, /cores/, JSON.stringify(beta));

  const detailRes = await tool(pair.doorA, "t1", "station_list", { station: "beta" });
  assert.equal(detailRes.error, false, detailRes.text);
  const detail = JSON.parse(detailRes.text);
  assert.equal(detail.version, "0.1.9521");
  assert.equal(detail.tasks, true);
  assert.equal(detail.sync, 1);
  assert.ok(typeof detail.os === "string" && typeof detail.arch === "string", detailRes.text);
  assert.ok(detail.load.cpus >= 1, JSON.stringify(detail.load));
  assert.ok(detail.load.memory.totalBytes > 0, JSON.stringify(detail.load));
  assert.ok(detail.load.disk.totalBytes > 0, JSON.stringify(detail.load));

  // HTTP service on Station B's machine reached via Station A's `/peer/beta/<port>/...`.
  const payload = Buffer.from([0, 1, 2, 127, 128, 254, 255]);
  const svc = httpServer((req, res) => {
    res.writeHead(200, { "content-type": "application/octet-stream", "x-req": `${req.method} ${req.url}` }).end(payload);
  });
  await new Promise<void>((r) => svc.listen(0, "127.0.0.1", () => r()));
  cleanups.push(() => { svc.close(); });
  const svcPort = (svc.address() as AddressInfo).port;
  const peerPath = `/peer/beta/${svcPort}/ping?k=v`;

  // Valid loopback callers pass.
  const ok1 = await httpRaw(pair.doorA, peerPath);
  assert.equal(ok1.status, 200, ok1.body.toString());
  assert.equal(ok1.headers["x-req"], "GET /ping?k=v");
  assert.deepEqual(ok1.body, payload);
  const okLocalhost = await httpRaw(pair.doorA, peerPath, { headers: { host: `localhost:${pair.doorA}` } });
  assert.equal(okLocalhost.status, 200, okLocalhost.body.toString());
  const okNullOrigin = await httpRaw(pair.doorA, peerPath, { headers: { origin: "null" } });
  assert.equal(okNullOrigin.status, 200, okNullOrigin.body.toString());

  // `/peer/` gate refuses DNS rebinding (wrong Host), wrong port, browser Origin, and sandboxed cross-site frame.
  assert.equal((await httpRaw(pair.doorA, peerPath, { headers: { host: `evil.example:${pair.doorA}` } })).status, 403);
  assert.equal((await httpRaw(pair.doorA, peerPath, { headers: { host: "127.0.0.1:1" } })).status, 403);
  assert.equal((await httpRaw(pair.doorA, peerPath, { headers: { origin: "https://evil.example" } })).status, 403);
  assert.equal((await httpRaw(pair.doorA, peerPath, { headers: { origin: `http://127.0.0.1:${pair.doorA}` } })).status, 403);
  assert.equal(
    (await httpRaw(pair.doorA, peerPath, { headers: { origin: "null", "sec-fetch-site": "cross-site" } })).status,
    403,
  );

  // Bad target station / self / invalid port refused cleanly.
  assert.equal((await httpRaw(pair.doorA, `/peer/ghost/${svcPort}/`)).status, 404);
  assert.equal((await httpRaw(pair.doorA, `/peer/alpha/${svcPort}/`)).status, 400);
  assert.equal((await httpRaw(pair.doorA, `/peer/beta/0/`)).status, 404);
  assert.equal((await httpRaw(pair.doorA, `/peer/beta/65536/`)).status, 404);

  // Unauthorized peer (iroh endpoint not in workspace roster) attempting `stillfail/http/1` against Station B is refused.
  const intruder = await addon!.bind({
    secretKey: randomBytes(32),
    alpns: [Buffer.from("client/1")],
    relayUrls: [],
    discovery: false,
    bindAddr: "127.0.0.1:0",
  });
  cleanups.push(() => intruder.close());
  const evilConn = await intruder.connect({ id: pair.idB, ips: [`127.0.0.1:${pair.portB}`] }, Buffer.from("stillfail/http/1"));
  const evilStream = await evilConn.openBi();
  await line(evilStream, { workspace: "w1", port: svcPort, method: "GET", path: "/", headers: [] });
  await evilStream.finish();
  const evilHead = await new Reader(evilStream).line().catch(() => ({ status: 403 }));
  assert.ok(evilHead.status === 403 || evilHead.status >= 400, JSON.stringify(evilHead));

  await pair.stop();
});

// ── 2. Cross-station `station_task` + `station_file` + `dirsync` mirror + `back` + `clean` + `stop` ─────────────────
test("cross-station station_task, chunked station_file, dirsync incremental mirror, back auto-download, clean, and stop", { skip }, async () => {
  const pair = await startPair({ build: "9522" });
  const workA = fresh("workA");
  const storeA = Store.open(join(pair.dataA, "stillfail.db"), join(pair.dataA, "archive"), {
    currentTimeMillisUnsafe: () => Date.now(),
  } as never);
  storeA.insertSession({
    key: "s1", connect: "ember", runtime: "claude", profile: "cc", workspace: workA,
    token: "t1", createdAt: Date.now(), lastActiveAt: Date.now(),
  });
  storeA.close();

  // Wait until Station A can reach Station B.
  await given("alpha reaches beta", async () => {
    const r = await tool(pair.doorA, "t1", "station_list", { station: "beta" });
    return !r.error && JSON.parse(r.text).tasks === true ? true : null;
  });

  // ── Part A: multi-chunk upload (>256 KiB), remote execution, log/list/get, multi-chunk download & overwrite guard ──
  const inputBuf = randomBytes(320 * 1024 + 19);
  writeFileSync(join(workA, "big-in.bin"), inputBuf);
  const prepA = await tool(pair.doorA, "t1", "station_task", {
    station: "beta",
    key: "k-chunk",
    action: "prepare",
    name: "chunk-copy",
    command: "cp big-in.bin big-out.bin; printf 'copied-ok\\n'",
  });
  assert.equal(prepA.error, false, prepA.text);
  assert.deepEqual(JSON.parse(prepA.text), { key: "k-chunk", prepared: true });

  const up = await tool(pair.doorA, "t1", "station_file", {
    station: "beta",
    key: "k-chunk",
    direction: "upload",
    path: "big-in.bin",
    local: "big-in.bin",
  });
  assert.equal(up.error, false, up.text);

  const startA = await tool(pair.doorA, "t1", "station_task", {
    station: "beta",
    key: "k-chunk",
    action: "start",
  });
  assert.equal(startA.error, false, startA.text);
  assert.match(JSON.parse(startA.text).job.id, /^remote_/);

  const doneA = await given("k-chunk exited", async () => {
    const r = await tool(pair.doorA, "t1", "station_task", { station: "beta", key: "k-chunk", action: "get" });
    if (r.error) return null;
    const g = JSON.parse(r.text);
    return g.job?.state === "exited" ? g : null;
  });
  assert.equal(doneA.job.exitCode, 0, JSON.stringify(doneA));
  const logA = await tool(pair.doorA, "t1", "station_task", { station: "beta", key: "k-chunk", action: "log" });
  assert.equal(logA.error, false, logA.text);
  assert.equal(JSON.parse(logA.text).log.trim(), "copied-ok");

  const down = await tool(pair.doorA, "t1", "station_file", {
    station: "beta",
    key: "k-chunk",
    direction: "download",
    path: "big-out.bin",
    local: "back/big-out.bin",
  });
  assert.equal(down.error, false, down.text);
  const downloadedBuf = readFileSync(join(workA, "back", "big-out.bin"));
  assert.equal(sha256(downloadedBuf), sha256(inputBuf), "multi-chunk upload+download preserved every byte");

  // Overwrite protection: downloading again to the same existing local path must be refused.
  const overwrite = await tool(pair.doorA, "t1", "station_file", {
    station: "beta",
    key: "k-chunk",
    direction: "download",
    path: "big-out.bin",
    local: "back/big-out.bin",
  });
  assert.equal(overwrite.error, true, `expected overwrite refusal, got: ${overwrite.text}`);

  // ── Part B: dirsync initial + incremental mirror + `back` auto-download + `mirrors` + `clean` ──
  const git = (cwd: string, ...args: string[]) => {
    const r = spawnSync("git", ["-c", "user.email=t@t", "-c", "user.name=t", ...args], { cwd, encoding: "utf8" });
    assert.equal(r.status, 0, `git ${args.join(" ")}: ${r.stderr}`);
  };
  const repoDir = fresh("repo");
  git(repoDir, "init", "-q");
  writeFileSync(join(repoDir, "a.txt"), "v1-committed\n");
  git(repoDir, "add", ".");
  git(repoDir, "commit", "-qm", "init");
  writeFileSync(join(repoDir, "u.txt"), "v1-untracked\n");

  const prepDir1 = await tool(pair.doorA, "t1", "station_task", {
    station: "beta",
    key: "k-dir1",
    action: "prepare",
    name: "dirsync-1",
    dir: repoDir,
    back: ["artifact1.txt"],
    command: "cat a.txt u.txt; echo art-one > artifact1.txt",
  });
  assert.equal(prepDir1.error, false, prepDir1.text);
  const startDir1 = await given("k-dir1 synced and started", async () => {
    const r = await tool(pair.doorA, "t1", "station_task", { station: "beta", key: "k-dir1", action: "start" });
    assert.equal(r.error, false, r.text);
    const parsed = JSON.parse(r.text);
    return parsed.syncing === true ? null : parsed;
  }, 30_000);
  assert.match(startDir1.job.id, /^remote_/);

  const gotDir1 = await given("k-dir1 exited", async () => {
    const r = await tool(pair.doorA, "t1", "station_task", { station: "beta", key: "k-dir1", action: "get" });
    const g = JSON.parse(r.text);
    return g.job?.state === "exited" || g.job?.state === "failed" ? g : null;
  });
  assert.equal(gotDir1.job.exitCode, 0, JSON.stringify(gotDir1));
  assert.equal(gotDir1.log.trim(), "v1-committed\nv1-untracked");

  const back1Path = join(workA, "station-back", "k-dir1", "artifact1.txt");
  await given("k-dir1 back artifact downloaded", () => (existsSync(back1Path) ? true : null), 30_000);
  assert.equal(readFileSync(back1Path, "utf8"), "art-one\n");

  const mirrors1 = await given("mirror idle after k-dir1", async () => {
    const r = await tool(pair.doorA, "t1", "station_task", { station: "beta", action: "mirrors" });
    const m = JSON.parse(r.text).mirrors;
    return m.length === 1 && m[0].busy === false ? m : null;
  }, 30_000);
  const mirrorName = mirrors1[0].name as string;
  const mirrorPath = mirrors1[0].path as string;
  assert.equal(existsSync(mirrorPath), true);

  // Incremental sync on the same mirror: modify `a.txt` and add `b.txt`.
  writeFileSync(join(repoDir, "a.txt"), "v2-modified\n");
  writeFileSync(join(repoDir, "b.txt"), "v2-added\n");
  const prepDir2 = await tool(pair.doorA, "t1", "station_task", {
    station: "beta",
    key: "k-dir2",
    action: "prepare",
    name: "dirsync-2",
    dir: repoDir,
    back: ["artifact2.txt"],
    command: "cat a.txt b.txt u.txt; echo art-two > artifact2.txt",
  });
  assert.equal(prepDir2.error, false, prepDir2.text);
  await given("k-dir2 synced and started", async () => {
    const r = await tool(pair.doorA, "t1", "station_task", { station: "beta", key: "k-dir2", action: "start" });
    assert.equal(r.error, false, r.text);
    const parsed = JSON.parse(r.text);
    return parsed.syncing === true ? null : parsed;
  }, 30_000);
  const gotDir2 = await given("k-dir2 exited", async () => {
    const r = await tool(pair.doorA, "t1", "station_task", { station: "beta", key: "k-dir2", action: "get" });
    const g = JSON.parse(r.text);
    return g.job?.state === "exited" || g.job?.state === "failed" ? g : null;
  });
  assert.equal(gotDir2.job.exitCode, 0, JSON.stringify(gotDir2));
  assert.equal(gotDir2.log.trim(), "v2-modified\nv2-added\nv1-untracked");
  const back2Path = join(workA, "station-back", "k-dir2", "artifact2.txt");
  await given("k-dir2 back artifact downloaded", () => (existsSync(back2Path) ? true : null), 30_000);
  assert.equal(readFileSync(back2Path, "utf8"), "art-two\n");

  const mirrors2 = await given("mirror idle after k-dir2", async () => {
    const r = await tool(pair.doorA, "t1", "station_task", { station: "beta", action: "mirrors" });
    const m = JSON.parse(r.text).mirrors;
    return m.length === 1 && m[0].busy === false ? m : null;
  }, 30_000);
  assert.equal(mirrors2[0].name, mirrorName, "incremental sync reused the same mirror");

  // Clean mirror and confirm removal.
  const cleaned = await given("mirror cleaned", async () => {
    const r = await tool(pair.doorA, "t1", "station_task", { station: "beta", action: "clean", mirror: mirrorName });
    assert.equal(r.error, false, r.text);
    const parsed = JSON.parse(r.text);
    return parsed.removed === true ? parsed : null;
  });
  assert.deepEqual(cleaned, { mirror: mirrorName, removed: true });
  assert.equal(existsSync(mirrorPath), false);
  const mirrorsAfter = JSON.parse((await tool(pair.doorA, "t1", "station_task", { station: "beta", action: "mirrors" })).text);
  assert.deepEqual(mirrorsAfter.mirrors, []);

  // ── Part C: `stop` terminates a running remote task on Station B ──
  const prepStop = await tool(pair.doorA, "t1", "station_task", {
    station: "beta",
    key: "k-stop",
    action: "prepare",
    name: "sleeper",
    command: "sleep 600",
  });
  assert.equal(prepStop.error, false, prepStop.text);
  const startStop = await tool(pair.doorA, "t1", "station_task", {
    station: "beta",
    key: "k-stop",
    action: "start",
  });
  assert.equal(startStop.error, false, startStop.text);
  const remoteJobId = JSON.parse(startStop.text).job.id as string;

  const storeB = Store.open(join(pair.dataB, "stillfail.db"), join(pair.dataB, "archive"), {
    currentTimeMillisUnsafe: () => Date.now(),
  } as never);
  try {
    const pgid = await given("remote sleeper pgid recorded on beta", () => storeB.getJob(remoteJobId)?.pgid ?? null);
    assert.ok(alive(pgid, true));
    const stopped = await tool(pair.doorA, "t1", "station_task", { station: "beta", key: "k-stop", action: "stop" });
    assert.equal(stopped.error, false, stopped.text);
    await given("remote sleeper group gone", () => (!alive(pgid, true) ? true : null));
    const afterStop = await given("k-stop state stopped", async () => {
      const r = await tool(pair.doorA, "t1", "station_task", { station: "beta", key: "k-stop", action: "get" });
      const g = JSON.parse(r.text);
      return g.job?.state === "stopped" ? g : null;
    });
    assert.equal(afterStop.job.state, "stopped");
  } finally {
    storeB.close();
  }

  await pair.stop();
});

// ── 3. `peer_forward` TCP port forwarding ───────────────────────────────────────────────────────────────────────────
test("peer_forward forwards TCP traffic bidirectionally across two MoonBit stations, respects local_port, lists, and closes cleanly", { skip }, async () => {
  const pair = await startPair({ build: "9523" });
  const workA = fresh("workA");
  const storeA = Store.open(join(pair.dataA, "stillfail.db"), join(pair.dataA, "archive"), {
    currentTimeMillisUnsafe: () => Date.now(),
  } as never);
  storeA.insertSession({
    key: "s1", connect: "ember", runtime: "claude", profile: "cc", workspace: workA,
    token: "t1", createdAt: Date.now(), lastActiveAt: Date.now(),
  });
  storeA.close();

  await given("alpha reaches beta", async () => {
    const r = await tool(pair.doorA, "t1", "station_list", { station: "beta" });
    return !r.error && JSON.parse(r.text).tasks === true ? true : null;
  });

  // Local TCP echo server on Station B's host (prefixes "echo:" and echoes all bytes until EOF).
  const echoSrv = tcpServer({ allowHalfOpen: true }, (socket) => {
    socket.write(Buffer.from("echo:"));
    socket.on("data", (chunk) => socket.write(chunk));
    socket.on("end", () => socket.end());
  });
  await new Promise<void>((r) => echoSrv.listen(0, "127.0.0.1", () => r()));
  cleanups.push(() => { echoSrv.close(); });
  const echoPort = (echoSrv.address() as AddressInfo).port;

  // Open forward with explicit `local_port` (different from `echoPort` to avoid same-host collision and verify local_port honoring).
  const wantedLocal = await freeTcpPort();
  const opened = await tool(pair.doorA, "t1", "peer_forward", {
    station: "beta",
    port: echoPort,
    local_port: wantedLocal,
  });
  assert.equal(opened.error, false, opened.text);
  const fwd = JSON.parse(opened.text);
  assert.equal(fwd.local, `127.0.0.1:${wantedLocal}`, `expected local_port ${wantedLocal}, got ${opened.text}`);
  assert.equal(fwd.port, echoPort);

  // Bidirectional binary TCP exchange (>128 KiB) with half-close.
  const sent = randomBytes(160 * 1024 + 7);
  const echoed = await new Promise<Buffer>((resolve, reject) => {
    const sock = tcpConnect({ host: "127.0.0.1", port: wantedLocal, allowHalfOpen: true });
    const parts: Buffer[] = [];
    sock.on("data", (d: Buffer) => parts.push(d));
    sock.once("end", () => resolve(Buffer.concat(parts)));
    sock.once("error", reject);
    sock.once("connect", () => {
      sock.write(sent);
      sock.end();
    });
  });
  assert.equal(sha256(echoed), sha256(Buffer.concat([Buffer.from("echo:"), sent])));

  // List active forwards.
  const listed = await tool(pair.doorA, "t1", "peer_forward", {});
  assert.equal(listed.error, false, listed.text);
  const items = JSON.parse(listed.text);
  assert.equal(items.length, 1, listed.text);
  assert.equal(items[0].local, `127.0.0.1:${wantedLocal}`);

  // Close forward and verify cleanup.
  const closed = await tool(pair.doorA, "t1", "peer_forward", { close: wantedLocal });
  assert.equal(closed.error, false, closed.text);
  assert.match(closed.text, new RegExp(`Closed 127\\.0\\.0\\.1:${wantedLocal}`));
  assert.equal((await tool(pair.doorA, "t1", "peer_forward", {})).text, "No forwarded ports.");

  // Connecting after close must fail.
  await given("forwarded port closed", async () => {
    const refused = await new Promise<boolean>((resolve) => {
      const s = tcpConnect({ host: "127.0.0.1", port: wantedLocal });
      s.once("connect", () => {
        s.destroy();
        resolve(false);
      });
      s.once("error", () => resolve(true));
    });
    return refused ? true : null;
  });

  await pair.stop();
});

// ── 4. `xshare` cross-workspace sharing & revocation ────────────────────────────────────────────────────────────────
test("xshare shares a chat across workspaces with read-only / write / revocation boundaries on two MoonBit stations", { skip }, async () => {
  const pair = await startPair({
    wsA: "w1",
    wsNameA: "Team",
    wsB: "w2",
    wsNameB: "Home",
    bridgeWs: "w-bridge",
    build: "9524",
  });
  const [workA1, workA2, workB] = [fresh("wa1"), fresh("wa2"), fresh("wb")];

  // Seed two chats on Station A (w1): `c-shared` and `c-private`, and one chat on Station B (w2): `c-b`.
  const storeA = Store.open(join(pair.dataA, "stillfail.db"), join(pair.dataA, "archive"), {
    currentTimeMillisUnsafe: () => Date.now(),
  } as never);
  const tShared = storeA.openThread("ember", "c-shared", "c-shared", "Release Plan", "alice@team.test");
  storeA.insertMessage({
    thread: tShared.id, ts: "1700000001.000", authorKind: "person", author: "alice@team.test",
    text: "the release plan is Friday", at: Date.now(),
  });
  storeA.insertSession({
    key: "c-shared", connect: "ember", runtime: "claude", profile: "cc", workspace: workA1,
    token: "ta1", createdAt: Date.now(), lastActiveAt: Date.now(),
  });
  storeA.joinThread(tShared.id, "c-shared", "ember");

  const tPriv = storeA.openThread("ember", "c-private", "c-private", "Private Notes", "alice@team.test");
  storeA.insertMessage({
    thread: tPriv.id, ts: "1700000002.000", authorKind: "person", author: "alice@team.test",
    text: "top secret salary table", at: Date.now(),
  });
  storeA.insertSession({
    key: "c-private", connect: "ember", runtime: "claude", profile: "cc", workspace: workA2,
    token: "ta2", createdAt: Date.now(), lastActiveAt: Date.now(),
  });
  storeA.joinThread(tPriv.id, "c-private", "ember");
  storeA.close();

  const storeB = Store.open(join(pair.dataB, "stillfail.db"), join(pair.dataB, "archive"), {
    currentTimeMillisUnsafe: () => Date.now(),
  } as never);
  const tB = storeB.openThread("ember", "c-b", "c-b", "Home Chat", "bob@home.test");
  storeB.insertMessage({
    thread: tB.id, ts: "1700000003.000", authorKind: "person", author: "bob@home.test",
    text: "checking Team's release plan", at: Date.now(),
  });
  storeB.insertSession({
    key: "c-b", connect: "ember", runtime: "claude", profile: "cc", workspace: workB,
    token: "tb", createdAt: Date.now(), lastActiveAt: Date.now(),
  });
  storeB.joinThread(tB.id, "c-b", "ember");
  storeB.close();

  const linkShared = `${pair.plane.origin}/o/w1/${pair.idA}/c-shared`;
  const linkPrivate = `${pair.plane.origin}/o/w1/${pair.idA}/c-private`;

  // Before sharing: reading `c-shared` from Station B is refused.
  const beforeRead = await tool(pair.doorB, "tb", "chat_read", { chat: linkShared });
  assert.equal(beforeRead.error, true, `expected refusal before sharing, got: ${beforeRead.text}`);

  // Trust Station A on Station B (w2) and share `c-shared` read-only from Station A (w1) to w2.
  const trustRes = await httpRaw(pair.doorB, "/admin-api/xshare/hosts", {
    method: "PUT",
    body: JSON.stringify({ workspace: "w1", name: "Team", station: pair.idA, stationName: "alpha" }),
  });
  assert.equal(trustRes.status, 200, trustRes.body.toString());

  const shareRo = await httpRaw(pair.doorA, "/admin-api/sessions/c-shared/xshare", {
    method: "PUT",
    body: JSON.stringify({
      to: [{ workspace: "w2", name: "Home", stations: [{ id: pair.idB, name: "beta" }] }],
      write: false,
    }),
  });
  assert.equal(shareRo.status, 200, shareRo.body.toString());

  // Station B's `chat_list` sees `c-shared` as read-only from "Team".
  await given("beta chat_list shows shared read-only chat", async () => {
    const r = await tool(pair.doorB, "tb", "chat_list", {});
    return !r.error && r.text.includes(linkShared) && r.text.includes("read only") ? r.text : null;
  });

  // Reading `c-shared` succeeds; reading `c-private` or writing to read-only `c-shared` is refused.
  const readShared = await tool(pair.doorB, "tb", "chat_read", { chat: linkShared });
  assert.equal(readShared.error, false, readShared.text);
  assert.ok(readShared.text.includes("the release plan is Friday"), readShared.text);

  const readPriv = await tool(pair.doorB, "tb", "chat_read", { chat: linkPrivate });
  assert.equal(readPriv.error, true, `unshared chat must be refused: ${readPriv.text}`);
  assert.match(readPriv.text, /not shared with your workspace/);

  const sendRo = await tool(pair.doorB, "tb", "session_send", { to: linkShared, text: "should fail" });
  assert.equal(sendRo.error, true, `read-only chat must refuse write: ${sendRo.text}`);
  assert.match(sendRo.text, /read only/);

  // Upgrade to writable (`write: true`): Station B can send a message to `c-shared`.
  const shareRw = await httpRaw(pair.doorA, "/admin-api/sessions/c-shared/xshare", {
    method: "PUT",
    body: JSON.stringify({
      to: [{ workspace: "w2", name: "Home", stations: [{ id: pair.idB, name: "beta" }] }],
      write: true,
    }),
  });
  assert.equal(shareRw.status, 200, shareRw.body.toString());

  await given("beta chat_list shows writable share", async () => {
    const r = await tool(pair.doorB, "tb", "chat_list", {});
    return !r.error && r.text.includes(linkShared) && r.text.includes("you may send to it") ? true : null;
  });

  const sendRw = await tool(pair.doorB, "tb", "session_send", { to: linkShared, text: "hello from Home workspace" });
  assert.equal(sendRw.error, false, sendRw.text);

  // Revoke share (`to: []`): disappears from Station B's list and `chat_read` is refused again.
  const revokeRes = await httpRaw(pair.doorA, "/admin-api/sessions/c-shared/xshare", {
    method: "PUT",
    body: JSON.stringify({ to: [], write: false }),
  });
  assert.equal(revokeRes.status, 200, revokeRes.body.toString());

  await given("revoked chat gone from beta chat_list", async () => {
    const r = await tool(pair.doorB, "tb", "chat_list", {});
    return !r.error && !r.text.includes(linkShared) ? true : null;
  });
  const afterRevoke = await tool(pair.doorB, "tb", "chat_read", { chat: linkShared });
  assert.equal(afterRevoke.error, true, `revoked share must be refused: ${afterRevoke.text}`);

  await pair.stop();
});

// ── 5. Safe mode `lock`: pinning, non-member refusal, role cap, mesh sync, and immediate member revocation ──────────
test("safe-mode lock: owner pins lock via /lock, syncs across stations, rejects non-members/evil keys, and revokes members immediately", { skip }, async () => {
  const WS = "01HLOCKTESTWORKSPACE000001";
  const grant = new GrantKey("k1");
  const evilGrant = new GrantKey("k-evil");
  const pair = await startPair({ wsA: WS, wsB: WS, wsNameA: "LockedTeam", grant, build: "9525" });

  const alice = { sub: "alice", signer: ed(), base: ed() };
  const bob = { sub: "bob", signer: ed(), base: ed() };
  const carol = { sub: "carol", signer: ed(), base: ed() };
  const stranger = { sub: "stranger", base: ed() };

  const client = await addon!.bind({
    secretKey: randomBytes(32),
    alpns: [Buffer.from("client/1")],
    relayUrls: [],
    discovery: false,
    bindAddr: "127.0.0.1:0",
  });
  cleanups.push(() => client.close());
  const endpointId = client.id();
  const now = Math.floor(Date.now() / 1000);
  const credOf = (key: GrantKey, sub: string, role: string) =>
    key.credential(
      { typ: "stillfail-member+jwt" },
      { iss: "stillfail-cloud", sub, email: `${sub}@x.co`, name: sub, ws: WS, role, device: endpointId, sid: `sid-${sub}`, iat: now, exp: now + 3600 },
    );
  const proofOf = (who: { base: EdKey }) => ({ device: who.base.hex, proof: who.base.sign(endpointBytes(WS, endpointId)) });

  const genesisEntry = signLockEntry(
    {
      v: 1,
      ws: WS,
      seq: 0,
      prev: null,
      at: now,
      kind: "genesis",
      body: {
        owner: "alice",
        origins: ["https://app.still.fail"],
        rp_id: "app.still.fail",
        cloud_keys: { keys: [grant.jwk] },
        members: [
          { sub: "alice", email: "alice@x.co", role: "owner" },
          { sub: "bob", email: "bob@x.co", role: "admin" },
          { sub: "carol", email: "carol@x.co", role: "member" },
        ],
        devices: [alice, bob, carol].map((p) => ({
          id: p.base.hex,
          sub: p.sub,
          kind: "app",
          label: p.sub,
          sign_key: p.signer.id,
        })),
        passkeys: [],
        stations: [
          { key: pair.idA, name: "alpha" },
          { key: pair.idB, name: "beta" },
        ],
        gateways: [],
      },
    },
    alice.signer,
  );
  const genesisHash = entryHash(genesisEntry);

  const dialStation = async (id: string, port: number) =>
    given(`mesh connect ${id.slice(0, 8)}`, () => client.connect({ id, ips: [`127.0.0.1:${port}`] }, Buffer.from("stillfail/admin/1")));

  // Non-owner (`bob`, admin) cannot pin genesis on unlocked Station A.
  const bobConn = await dialStation(pair.idA, pair.portA);
  assert.equal((await member(bobConn, credOf(grant, "bob", "admin"), proofOf(bob))).ok, true);
  const [bobPinStatus] = await memberAsk(bobConn, "POST", "/admin/api/lock", { entries: [genesisEntry] });
  assert.equal(bobPinStatus, 403, "admin must not pin workspace lock");

  // Owner (`alice`) pins genesis on Station A -> 200 and `mesh/lock.json` written.
  const aliceConnA = await dialStation(pair.idA, pair.portA);
  assert.equal((await member(aliceConnA, credOf(grant, "alice", "owner"), proofOf(alice))).ok, true);
  const [pinStatus, pinBody] = await memberAsk(aliceConnA, "POST", "/admin/api/lock", { entries: [genesisEntry] });
  assert.equal(pinStatus, 200, JSON.stringify(pinBody));
  assert.equal(pinBody.head.seq, 0);
  assert.equal(pinBody.head.genesis, genesisHash);
  await given("alpha lock.json persisted", () => readJson(join(pair.dataA, "mesh", "lock.json"))?.entries?.length === 1);

  // Station B syncs the pinned lock over mesh (`follow_lock` / `lock.*`), or accepts it.
  // Push lock head frame to Station B as the control plane would, or let peer sync propagate.
  const aliceConnB = await dialStation(pair.idB, pair.portB);
  assert.equal((await member(aliceConnB, credOf(grant, "alice", "owner"), proofOf(alice))).ok, true);
  const [pinBStatus] = await memberAsk(aliceConnB, "POST", "/admin/api/lock", { entries: [genesisEntry] });
  assert.equal(pinBStatus, 200);
  await given("beta lock.json persisted", () => readJson(join(pair.dataB, "mesh", "lock.json"))?.entries?.length === 1);

  // Evil grant key refused even with valid device proof.
  const evilConn = await dialStation(pair.idA, pair.portA);
  const evilHello = await member(evilConn, credOf(evilGrant, "alice", "owner"), proofOf(alice));
  assert.notEqual(evilHello.ok, true, "credential signed by evil key must be refused");

  // Non-member / unknown device refused even with valid cloud grant key.
  const strangerConn = await dialStation(pair.idA, pair.portA);
  const strangerHello = await member(strangerConn, credOf(grant, "stranger", "owner"), proofOf(stranger));
  assert.notEqual(strangerHello.ok, true, "device not in lock must be refused");

  // Carol (member in lock) is admitted, and her role is capped to `member` even if cloud claims `owner`.
  const carolConn = await dialStation(pair.idA, pair.portA);
  const carolHello = await member(carolConn, credOf(grant, "carol", "owner"), proofOf(carol));
  assert.equal(carolHello.ok, true, JSON.stringify(carolHello));
  const [carolMarkStatus] = await memberAsk(carolConn, "PUT", "/admin/api/station-mark", { name: "Hijacked" });
  assert.equal(carolMarkStatus, 403, "lock must cap carol's role to member (not owner)");

  // Immediate member revocation: Alice signs `member.remove` for Carol (seq 1) and posts to Station A.
  const removeCarol = signLockEntry(
    {
      v: 1,
      ws: WS,
      seq: 1,
      prev: genesisHash,
      at: now + 1,
      kind: "member.remove",
      body: { sub: "carol" },
    },
    alice.signer,
  );
  const [revStatus, revBody] = await memberAsk(aliceConnA, "POST", "/admin/api/lock", { entries: [removeCarol] });
  assert.equal(revStatus, 200, JSON.stringify(revBody));
  assert.equal(revBody.head.seq, 1);

  // Carol's new connection to Station A is refused immediately.
  const carolAfterA = await dialStation(pair.idA, pair.portA);
  const carolRefusedA = await member(carolAfterA, credOf(grant, "carol", "member"), proofOf(carol));
  assert.notEqual(carolRefusedA.ok, true, "revoked member must be refused immediately on alpha");

  // Station B syncs seq 1 from Station A over the mesh automatically (follow_lock), then refuses Carol too.
  await given("beta synced lock seq 1 from alpha over mesh", async () => {
    const [st, body] = await memberAsk(aliceConnB, "GET", "/admin/api/lock");
    return st === 200 && body?.head?.seq === 1 ? body : null;
  });
  const carolAfterB = await dialStation(pair.idB, pair.portB);
  const carolRefusedB = await member(carolAfterB, credOf(grant, "carol", "member"), proofOf(carol));
  assert.notEqual(carolRefusedB.ok, true, "revoked member must be refused on beta after mesh lock sync");

  // Alice remains admitted and reads lock head seq 1.
  const [aliceGetStatus, aliceGetBody] = await memberAsk(aliceConnA, "GET", "/admin/api/lock");
  assert.equal(aliceGetStatus, 200);
  assert.equal(aliceGetBody.head.seq, 1);

  await pair.stop();
});
