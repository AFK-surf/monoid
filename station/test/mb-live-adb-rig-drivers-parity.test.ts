// Wave 3 Track I: Live pure-MoonBit station (`stillfail-reader run` + `stillfail-runner`, no Node on PATH) parity tests:
// 1. Rig mode & signed grants (dual-station loopback iroh mesh):
//    - Station A (whole) <-> Station B (rig, mode: "tasks")
//    - `station_list` identifies rig mode, unauthorized `station_task` refused before grant
//    - `station_use` card -> owner Ed25519 signed grant approval -> cross-station `station_task` succeeds
//    - Revocation & expiry re-refuse `station_task`
//    - Station <-> Rig mode switching (`POST /rigs/:id/full` + plane state; `POST /mode` + plane state)
// 2. ADB / Phone device tools closed loop (loopback iroh mesh phone + fake `adb`, no hardware):
//    - `device_list` shows lent phone, unauthorized session refused `phone_send`
//    - `device_use` posts approval card -> owner approves via `/admin/api/adb` -> `device_use` returns `-P <port> -s <serial>`
//    - `phone_send` stages file and completes phone fetch over mesh; unauthorized session stays refused; `done: true` revokes access
// 3. Multi-Runtime Drivers real-process closed loop (fake `claude`, `codex`, `agy` CLIs under real `stillfail-runner`):
//    - Running steer injects new message without dropping messages (#7585 / #7597)
//    - Running stop/interrupt aborts active turn and returns to idle
//    - Mid-turn process crash reports error and next turn spawns fresh process (reset/recovery)
import assert from "node:assert/strict";
import { type ChildProcess, spawn, spawnSync } from "node:child_process";
import { createHash, generateKeyPairSync, randomBytes, sign as nodeSign } from "node:crypto";
import { createSocket } from "node:dgram";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { createServer as httpServer, request as httpRequest } from "node:http";
import { type AddressInfo, createServer as tcpServer, type Server, type Socket } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { DatabaseSync } from "node:sqlite";
import { after, test } from "node:test";
import { WebSocketServer, type WebSocket } from "ws";
import { type GrantBody, type Kind, type Timeout, latest, signedBytes as rigSignedBytes } from "../../client/core-ts/src/rig-form.ts";
import { type Entry, entryHash, signedBytes as lockSignedBytes } from "../../shared/lock.ts";
import { loadMesh, type Connection, type Stream as MeshStream } from "../src/mesh/native.ts";
import { Reader } from "../src/mesh/wire.ts";
import { mbStationBinary } from "./mb-harness.ts";
import { Store } from "../src/store/store.ts";
import { GrantKey } from "./fake-control-plane.ts";

const binary = mbStationBinary();
const runner = process.env.STILLFAIL_RUNNER ?? "";
const addon = (() => {
  try {
    return loadMesh();
  } catch {
    return null;
  }
})();

function binOf(name: string): string {
  const search = [
    ...(process.env.PATH ?? "").split(":").filter((d) => d !== ""),
    "/usr/bin",
    "/bin",
    "/usr/sbin",
    "/sbin",
    "/usr/local/bin",
    "/opt/homebrew/bin",
  ];
  for (const d of search) {
    const at = join(d, name);
    if (existsSync(at)) return at;
  }
  return "";
}

const PYTHON3 = binOf("python3");
const CURL = binOf("curl");

const skipBase =
  binary === null
    ? "the MoonBit program (stillfail-reader) is not built here"
    : process.platform === "win32"
      ? "the launcher's descriptors are Unix's"
      : false;
const skipMesh = skipBase || (addon === null ? "the mesh addon is not built here (scripts/native.ts run mesh)" : false);
const skipAdb = skipMesh || (PYTHON3 === "" ? "python3 is not available for fake adb" : false);
const skipDrivers =
  skipBase ||
  (runner === "" || !existsSync(runner) ? "no stillfail-runner (run under scripts/native.ts run runner)" : false) ||
  (PYTHON3 === "" ? "python3 is not available for fake codex/agy CLIs" : false) ||
  (CURL === "" ? "curl is not available for fake claude CLI" : false);

const dirs: string[] = [];
// (short: Unix socket paths are capped at 104 bytes on macOS)
const fresh = (what: string) => {
  const dir = mkdtempSync(join(process.platform === "darwin" ? "/tmp" : tmpdir(), `mbi-${what}-`));
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
  await Promise.race([
    Promise.all(
      left.map((c) =>
        c.exitCode === null && c.signalCode === null ? new Promise<void>((r) => c.once("exit", () => r())) : undefined,
      ),
    ),
    new Promise((r) => setTimeout(r, 5_000).unref()),
  ]);
  for (const d of dirs) {
    const runners = join(d, "run", "runners");
    if (existsSync(runners)) {
      for (const f of readdirSync(runners)) {
        if (!f.endsWith(".json")) continue;
        try {
          const info = JSON.parse(readFileSync(join(runners, f), "utf8"));
          try {
            process.kill(-info.pgid, "SIGKILL");
          } catch {}
          try {
            process.kill(info.runner, "SIGKILL");
          } catch {}
        } catch {}
      }
    }
    rmSync(d, { recursive: true, force: true });
  }
});

const TOOLS = [
  "sh", "ps", "mv", "cat", "curl", "sleep", "echo", "printf", "env", "python3",
  "git", "ls", "find", "sort", "rm", "mkdir", "cp", "dirname", "basename",
  "sed", "tr", "head", "wc", "uname", "dd", "lsof", "awk",
];

function makeNoNodeBin(dir = fresh("path")): string {
  for (const t of TOOLS) {
    const found = binOf(t);
    if (found !== "" && !found.includes("node") && !existsSync(join(dir, t))) {
      symlinkSync(found, join(dir, t));
    }
  }
  assert.equal(existsSync(join(dir, "node")), false, "no node on PATH");
  return dir;
}

const noNode = (more: Record<string, string> = {}) => ({
  PATH: makeNoNodeBin(),
  HOME: process.env.HOME ?? tmpdir(),
  TMPDIR: tmpdir(),
  STILLFAIL_HELD_EVERY_MS: "300",
  STILLFAIL_NO_DISCOVERY: "1",
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

async function freeUdpPort(): Promise<number> {
  const socket = createSocket("udp4");
  await new Promise<void>((r) => socket.bind(0, "127.0.0.1", () => r()));
  const port = socket.address().port;
  await new Promise<void>((r) => socket.close(() => r()));
  return port;
}

function stationId(data: string): string {
  const r = spawnSync(binary!, ["id", "--data", data], { env: noNode(), encoding: "utf8" });
  assert.equal(r.status, 0, r.stderr);
  return r.stdout.trim();
}

const sha256 = (bytes: Uint8Array) => createHash("sha256").update(bytes).digest();

function ed() {
  const { privateKey, publicKey } = generateKeyPairSync("ed25519");
  const hex = (publicKey.export({ format: "der", type: "spki" }) as Buffer).subarray(-32).toString("hex");
  return { hex, id: `ed25519:${hex}`, sign: (bytes: Uint8Array) => nodeSign(null, bytes, privateKey).toString("hex") };
}
type EdKey = ReturnType<typeof ed>;

function personLock(sub: string) {
  const first = ed();
  const chain: Entry[] = [];
  const add = (kind: string, body: unknown, by: EdKey = first) => {
    const last = chain[chain.length - 1];
    const e = { v: 1, ws: `person:${sub}`, seq: chain.length, prev: last ? entryHash(last) : null, at: 1000, kind, body } as Omit<Entry, "sig">;
    chain.push({ ...e, sig: { key: by.id, alg: "Ed25519", sig: by.sign(lockSignedBytes(entryHash(e as Entry))) } } as Entry);
  };
  add("genesis", { sub, device: { key: first.id, id: ed().hex, label: "owner-app" } }, first);
  const says = <B>(kind: Kind, body: B, by: EdKey = first) => ({
    body,
    sig: { key: by.id, sig: by.sign(rigSignedBytes(kind, body, sha256)) },
  });
  return { sub, first, chain, add, says, genesis: () => entryHash(chain[0]!) };
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

async function launch(data: string, app: string, env: Record<string, string> = {}): Promise<Launched> {
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
      env: noNode(env),
    },
  );
  children.push(child);
  mcpSrv.close();
  loopSrv.close();
  const said: any[] = [];
  const waiters: (() => void)[] = [];
  const channel = (child.stdio as readonly unknown[])[5] as Socket;
  createInterface({ input: channel }).on("line", (line) => {
    try {
      said.push(JSON.parse(line));
      for (const w of waiters.splice(0)) w();
    } catch {}
  });
  let err = "";
  child.stderr!.on("data", (d) => (err += d));
  const next = (what: string, ok: (m: any) => boolean) =>
    new Promise<any>((resolve, reject) => {
      const timer = setTimeout(
        () => reject(new Error(`never said: ${what}; said ${JSON.stringify(said)}; stderr ${err}`)),
        25_000,
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
  const tell = (m: unknown) => {
    if (!channel.destroyed) channel.write(`${JSON.stringify(m)}\n`);
  };
  const stop = async () => {
    if (child.exitCode === null && child.signalCode === null) {
      tell({ op: "stop" });
      await Promise.race([ended, new Promise((r) => setTimeout(r, 15_000))]);
    }
  };
  return { child, said, next, tell, ended, err: () => err, stop };
}

function httpJson(
  port: number,
  path: string,
  method = "GET",
  body?: unknown,
  headers: Record<string, string> = {},
): Promise<{ status: number; json: any; raw: string }> {
  return new Promise((resolve, reject) => {
    const req = httpRequest(
      {
        host: "127.0.0.1",
        port,
        path,
        method,
        headers: { "content-type": "application/json", ...headers },
        agent: false,
      },
      (res) => {
        let raw = "";
        res.on("data", (d) => (raw += d));
        res.on("end", () => {
          let json: any = raw;
          try {
            json = raw === "" ? null : JSON.parse(raw);
          } catch {}
          resolve({ status: res.statusCode ?? 0, json, raw });
        });
      },
    );
    req.on("error", reject);
    req.end(body === undefined ? undefined : JSON.stringify(body));
  });
}

async function tool(port: number, token: string, name: string, args: unknown = {}): Promise<{ text: string; error: boolean }> {
  const res = await httpJson(
    port,
    "/mcp",
    "POST",
    { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name, arguments: args } },
    { authorization: `Bearer ${token}` },
  );
  assert.equal(res.status, 200, `${name} status ${res.status}: ${res.raw}`);
  assert.equal(res.json.error, undefined, `${name} rpc error: ${res.raw}`);
  return { text: res.json.result.content.map((c: any) => c.text).join("\n"), error: res.json.result.isError === true };
}

const writeLine = (stream: MeshStream, value: unknown) => stream.write(Buffer.from(JSON.stringify(value) + "\n"));

async function member(conn: Connection, credential: string) {
  const first = await conn.openBi();
  await writeLine(first, { credential, protocol: 2 });
  return new Reader(first).line();
}

async function memberAsk(conn: Connection, method: string, path: string, body?: unknown): Promise<[number, any]> {
  const stream = await conn.openBi();
  await writeLine(stream, { method, path, headers: { "content-type": "application/json" } });
  if (body !== undefined) await stream.write(Buffer.from(JSON.stringify(body)));
  await stream.finish();
  const reader = new Reader(stream);
  const head = await reader.line();
  return [head.status, JSON.parse((await reader.rest()).toString() || "null")];
}

const openStore = (data: string) =>
  Store.open(join(data, "stillfail.db"), join(data, "archive"), { currentTimeMillisUnsafe: () => Date.now() } as never);

async function controlPlane(stateFor: (stationId: string) => Record<string, unknown>) {
  const sockets: { station: string; socket: WebSocket }[] = [];
  const server = httpServer((_req, res) => {
    res.writeHead(200, { "content-type": "application/json" }).end("{}");
  });
  const wss = new WebSocketServer({ noServer: true });
  server.on("upgrade", (req, socket, head) => {
    if (!req.url?.startsWith("/v1/stations/connect")) return void socket.destroy();
    const st = String(req.headers["x-stillfail-station"] ?? "");
    wss.handleUpgrade(req, socket, head, (ws) => {
      sockets.push({ station: st, socket: ws });
      ws.on("message", (m) => {
        if (String(m) === "ping") ws.send("pong");
      });
      ws.send(JSON.stringify({ type: "state", relay_urls: [], revocations: [], ...stateFor(st) }));
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

// ═══════════════════════════════════════════════════════════════════════════════
// 1. Rig mode & signed grants (dual-station loopback iroh mesh)
// ═══════════════════════════════════════════════════════════════════════════════

test("Rig mode & signed grants dual-station mesh closed loop: station_list, refusal, station_use signed grant, task run, revoke, expiry, and mode switch", { skip: skipMesh }, async () => {
  const WS = "w-rig-parity";
  const [dataA, dataB, app, workA] = [fresh("riga"), fresh("rigb"), fresh("app"), fresh("wrka")];
  writeFileSync(join(app, "BUILD"), "10400\n");

  const [idA, idB] = [stationId(dataA), stationId(dataB)];
  const [portA, portB] = [await freeUdpPort(), await freeUdpPort()];
  const grantKey = new GrantKey();
  const owner = personLock("pat");

  const peerA = { id: idA, name: "station-a", ips: [`127.0.0.1:${portA}`] };
  const rigInfo = { id: idB, name: "rig-b", owner: "pat", owner_email: "pat@example.com", owner_name: "Pat", ips: [`127.0.0.1:${portB}`] };
  const rigSelf = { owner: "pat", owner_email: "pat@example.com", owner_name: "Pat", person: owner.genesis() };

  const plane = await controlPlane((st) =>
    st === idA
      ? { workspace: WS, workspace_name: "RigTeam", name: "station-a", peers: [peerA], rigs: [rigInfo], grant_keys: { keys: [grantKey.jwk] } }
      : { workspace: WS, workspace_name: "RigTeam", name: "rig-b", peers: [peerA], rig: { owner: "pat" }, grant_keys: { keys: [grantKey.jwk] } },
  );

  mkdirSync(join(dataA, "mesh"), { recursive: true });
  writeFileSync(
    join(dataA, "mesh", "cloud.json"),
    JSON.stringify({
      origin: plane.origin,
      station: idA,
      workspace: WS,
      workspace_name: "RigTeam",
      name: "station-a",
      relay_url: "",
      relay_urls: [],
      grant_keys: { keys: [grantKey.jwk] },
      peers: [peerA],
      rigs: [rigInfo],
      revocations: [],
    }),
  );

  mkdirSync(join(dataB, "mesh"), { recursive: true });
  writeFileSync(
    join(dataB, "mesh", "cloud.json"),
    JSON.stringify({
      origin: plane.origin,
      station: idB,
      workspace: WS,
      workspace_name: "RigTeam",
      name: "rig-b",
      relay_url: "",
      relay_urls: [],
      grant_keys: { keys: [grantKey.jwk] },
      peers: [peerA],
      rig: rigSelf,
      revocations: [],
    }),
  );

  const sA = openStore(dataA);
  sA.insertSession({
    key: "s1",
    connect: "chat",
    runtime: "claude",
    profile: "cc",
    workspace: workA,
    token: "tok-a1",
    createdBy: "pat@example.com",
    ws: WS,
    createdAt: Date.now(),
    lastActiveAt: Date.now(),
  } as never);
  const threadA = sA.openThread("chat", "CHAT", "1795100000.001000", "rig parity chat", "pat@example.com").id;
  sA.joinThread(threadA, "s1", "chat");
  sA.close();

  const stA = await launch(dataA, app, { STILLFAIL_MESH_BIND_ADDR: `127.0.0.1:${portA}` });
  await stA.next("station A ready", (m) => m.ready === true);
  const doorA = (await stA.next("station A mcp", (m) => m.serving === "mcp")).port as number;

  const stB = await launch(dataB, app, { STILLFAIL_MESH_BIND_ADDR: `127.0.0.1:${portB}` });
  await stB.next("rig B ready", (m) => m.ready === true);

  // Connect owner `pat` to Station A over mesh.
  const client = await addon!.bind({
    secretKey: randomBytes(32),
    alpns: [Buffer.from("client/1")],
    relayUrls: [],
    discovery: false,
    bindAddr: "127.0.0.1:0",
  });
  cleanups.push(() => client.close());
  const nowSec = () => Math.floor(Date.now() / 1000);
  const cred = grantKey.credential(
    { typ: "stillfail-member+jwt" },
    { iss: "stillfail-cloud", sub: "pat", email: "pat@example.com", name: "Pat", ws: WS, role: "owner", device: client.id(), sid: "s-pat", iat: nowSec(), exp: nowSec() + 3600 },
  );
  const connA = await given("member connects to station A", () =>
    client.connect({ id: idA, ips: [`127.0.0.1:${portA}`] }, Buffer.from("stillfail/admin/1")),
  );
  assert.equal((await member(connA, cred)).ok, true);

  // 1) station_list recognizes rig-b as mode: "tasks" and reachable, with no grant yet.
  const listedBefore = await given("station_list shows rig-b in tasks mode", async () => {
    const r = await tool(doorA, "tok-a1", "station_list", {});
    if (r.error) return null;
    const parsed = JSON.parse(r.text);
    const rigEntry = parsed.stations?.find((x: any) => x.id === idB || x.name === "rig-b");
    return rigEntry && rigEntry.mode === "tasks" && Array.isArray(rigEntry.hasAccess) ? rigEntry : null;
  });
  assert.equal(listedBefore.mode, "tasks");
  assert.match(String(listedBefore.thisChat ?? ""), /no grant|station_use/i);

  // 2) Unauthorized station_task before grant is refused.
  const prepUnauth = await tool(doorA, "tok-a1", "station_task", {
    station: "rig-b",
    action: "prepare",
    key: "k-unauth",
    name: "unauth check",
    command: "echo should-not-run",
  });
  assert.equal(prepUnauth.error, true, `unauthorized station_task must be refused: ${prepUnauth.text}`);
  assert.match(prepUnauth.text, /no grant|station_use|only runs tasks/i);

  // 3) Request grant via station_use -> approve with Ed25519 signed grant -> station_task succeeds.
  const ask1 = await tool(doorA, "tok-a1", "station_use", { station: "rig-b", reason: "run build on rig" });
  assert.equal(ask1.error, false, ask1.text);

  const dbA = new DatabaseSync(join(dataA, "stillfail.db"), { readOnly: true });
  let req1Id = "";
  let req1Chat = "";
  try {
    const row = await given("rig_requests row created", () =>
      dbA.prepare("SELECT id, status, body FROM rig_requests WHERE session = 's1' AND status = 'pending'").get() as
        | { id: string; status: string; body: string }
        | undefined,
    );
    req1Id = row.id;
    req1Chat = JSON.parse(row.body).chat ?? `CHAT/1795100000.001000`;
  } finally {
    dbA.close();
  }

  const signGrant = (requestId: string, timeout: Timeout, at = nowSec()) => {
    const body: GrantBody = {
      v: 1,
      sub: "pat",
      ws: WS,
      rig: idB,
      station: idA,
      session: "s1",
      chat: req1Chat,
      request: requestId,
      title: "rig parity chat",
      by: "pat@example.com",
      timeout,
      at,
      exp: latest(at, timeout),
    };
    return owner.says("grant", body);
  };

  const [dec1Status, dec1Body] = await memberAsk(connA, "POST", `/admin/api/rigs/requests/${req1Id}/decide`, {
    allow: true,
    signed: signGrant(req1Id, { kind: "idle", seconds: 3600 }),
    chain: owner.chain,
  });
  assert.equal(dec1Status, 200, JSON.stringify(dec1Body));
  assert.equal(dec1Body.request.status, "granted");

  // Wait for grant to be delivered to rig-b and reflected in station_list.
  await given("station_list reflects granted rig-b", async () => {
    const r = await tool(doorA, "tok-a1", "station_list", {});
    if (r.error) return false;
    const parsed = JSON.parse(r.text);
    const rigEntry = parsed.stations?.find((x: any) => x.id === idB);
    return rigEntry && /granted/i.test(String(rigEntry.thisChat ?? ""));
  });

  // Run a real task on rig-b now that grant is active.
  const prepOk = await tool(doorA, "tok-a1", "station_task", {
    station: "rig-b",
    action: "prepare",
    key: "k-ok-1",
    name: "echo on rig",
    command: "printf 'RIG-OK-TOKEN\\n'",
  });
  assert.equal(prepOk.error, false, prepOk.text);
  const startOk = await tool(doorA, "tok-a1", "station_task", {
    station: "rig-b",
    action: "start",
    key: "k-ok-1",
  });
  assert.equal(startOk.error, false, startOk.text);

  await given("rig task k-ok-1 finishes cleanly", async () => {
    const g = await tool(doorA, "tok-a1", "station_task", { station: "rig-b", action: "get", key: "k-ok-1" });
    if (g.error) return false;
    const parsed = JSON.parse(g.text);
    return parsed.job?.state === "exited" && parsed.job?.exitCode === 0;
  });
  const logOk = await tool(doorA, "tok-a1", "station_task", { station: "rig-b", action: "log", key: "k-ok-1", lines: 50 });
  assert.equal(logOk.error, false, logOk.text);
  assert.match(logOk.text, /RIG-OK-TOKEN/);

  // 4) Revoke grant via signed revoke -> subsequent station_task refused again.
  const revokeStmt = owner.says("revoke", { v: 1 as const, sub: "pat", ws: WS, rig: idB, request: req1Id, at: nowSec() });
  const [revStatus, revBody] = await memberAsk(connA, "POST", `/admin/api/rigs/requests/${req1Id}/revoke`, {
    signed: revokeStmt,
    chain: owner.chain,
  });
  if (revStatus !== 200) {
    const dbDbg = new DatabaseSync(join(dataA, "stillfail.db"), { readOnly: true });
    const rowDbg = dbDbg.prepare("SELECT id, status, body FROM rig_requests WHERE id = ?").get(req1Id);
    dbDbg.close();
    const gPath = join(dataB, "rig", "grants.json");
    const gTxt = existsSync(gPath) ? readFileSync(gPath, "utf8") : "<none>";
    assert.fail(`revoke returned ${revStatus}: ${JSON.stringify(revBody)}; db=${JSON.stringify(rowDbg)}; rigGrants=${gTxt}; errA=${stA.err()}; errB=${stB.err()}`);
  }

  await given("station_task refused again after revoke", async () => {
    const r = await tool(doorA, "tok-a1", "station_task", {
      station: "rig-b",
      action: "prepare",
      key: "k-after-revoke",
      name: "post-revoke",
      command: "echo nope",
    });
    return r.error && /no grant|station_use|only runs tasks/i.test(r.text);
  });

  // 5) Short-lived expiry grant: fixed 2 seconds -> works initially, then refused after expiry.
  const ask2 = await tool(doorA, "tok-a1", "station_use", { station: "rig-b", reason: "short-lived task" });
  assert.equal(ask2.error, false, ask2.text);
  const dbA2 = new DatabaseSync(join(dataA, "stillfail.db"), { readOnly: true });
  let req2Id = "";
  try {
    const row = await given("second pending rig request", () =>
      dbA2.prepare("SELECT id FROM rig_requests WHERE session = 's1' AND status = 'pending' AND id != ?").get(req1Id) as
        | { id: string }
        | undefined,
    );
    req2Id = row.id;
  } finally {
    dbA2.close();
  }
  const [dec2Status, dec2Body] = await memberAsk(connA, "POST", `/admin/api/rigs/requests/${req2Id}/decide`, {
    allow: true,
    signed: signGrant(req2Id, { kind: "fixed", seconds: 60 }, nowSec() - 58),
    chain: owner.chain,
  });
  assert.equal(dec2Status, 200, JSON.stringify(dec2Body));

  // Wait for the 2s fixed grant to expire and verify rig-b refuses a new task.
  await new Promise((r) => setTimeout(r, 3_000));
  await given("station_task refused after grant expiry", async () => {
    const r = await tool(doorA, "tok-a1", "station_task", {
      station: "rig-b",
      action: "prepare",
      key: "k-after-expiry",
      name: "post-expiry",
      command: "echo expired",
    });
    return r.error && /no grant|station_use|only runs tasks/i.test(r.text);
  });

  // 6) Mode switch Rig B -> Whole: signed `rig.full` + control plane state without `rig` -> B clears `rig` & exits via become_other.
  const fullStmt = owner.says("full", { v: 1 as const, sub: "pat", ws: WS, rig: idB, at: nowSec() });
  const [fullStatus, fullBody] = await memberAsk(connA, "POST", `/admin/api/rigs/${idB}/full`, {
    signed: fullStmt,
    chain: owner.chain,
  });
  assert.equal(fullStatus, 200, JSON.stringify(fullBody));
  assert.equal(fullBody.ok, true);

  await given("rig B persisted full_pending", () => {
    const c = JSON.parse(readFileSync(join(dataB, "mesh", "cloud.json"), "utf8"));
    return c.full_pending?.[WS] !== undefined;
  });
  plane.push(idB, {
    type: "state",
    workspace: WS,
    workspace_name: "RigTeam",
    name: "rig-b",
    peers: [peerA],
    relay_urls: [],
    revocations: [],
    grant_keys: { keys: [grantKey.jwk] },
  });
  assert.equal(await stB.ended, 0, `rig B should exit cleanly on become_other: ${stB.err()}`);
  const cloudBAfter = JSON.parse(readFileSync(join(dataB, "mesh", "cloud.json"), "utf8"));
  assert.equal(cloudBAfter.rig, undefined, "rig B switched to whole station in cloud.json");
  assert.equal(cloudBAfter.full_pending, undefined, "full_pending cleared");

  // 7) Mode switch Whole A -> Rig: POST /admin/api/mode + control plane state with `rig` -> A records `rig` & exits via become_other.
  const [modeStatus, modeBody] = await memberAsk(connA, "POST", "/admin/api/mode", {
    mode: "tasks",
    person: owner.genesis(),
  });
  assert.equal(modeStatus, 200, JSON.stringify(modeBody));
  assert.equal(modeBody.ok, true);

  await given("station A persisted rig_pending", () => {
    const c = JSON.parse(readFileSync(join(dataA, "mesh", "cloud.json"), "utf8"));
    return c.rig_pending?.[WS]?.owner === "pat";
  });
  plane.push(idA, {
    type: "state",
    workspace: WS,
    workspace_name: "RigTeam",
    name: "station-a",
    peers: [peerA],
    rig: { owner: "pat" },
    relay_urls: [],
    revocations: [],
    grant_keys: { keys: [grantKey.jwk] },
  });
  assert.equal(await stA.ended, 0, `station A should exit cleanly on become_other: ${stA.err()}`);
  const cloudAAfter = JSON.parse(readFileSync(join(dataA, "mesh", "cloud.json"), "utf8"));
  assert.equal(cloudAAfter.rig?.owner, "pat", "station A switched to rig mode in cloud.json");
  assert.equal(cloudAAfter.rig?.person, owner.genesis(), "station A pinned owner lock hash");

  assert.doesNotMatch(stA.err(), /SQLITE_BUSY|database is locked|unknown op/i);
  assert.doesNotMatch(stB.err(), /SQLITE_BUSY|database is locked|unknown op/i);
});

// ═══════════════════════════════════════════════════════════════════════════════
// 2. ADB / Phone device tools closed loop (mock adb + loopback mesh phone)
// ═══════════════════════════════════════════════════════════════════════════════

function installFakeAdb(dir: string, stateDir: string): void {
  makeNoNodeBin(dir);
  const py = `#!/usr/bin/env python3
import json, os, socket, sys

state_dir = os.environ["FAKE_ADB_DIR"]
args = sys.argv[1:]
with open(os.path.join(state_dir, "calls.jsonl"), "a") as f:
    f.write(json.dumps(args) + "\\n")

# Strip leading -P <port>
i = 0
port = None
while i < len(args):
    if args[i] == "-P" and i + 1 < len(args):
        port = args[i + 1]
        i += 2
    else:
        break
rest = args[i:]

if not rest:
    sys.exit(0)
if rest[0] == "server" and len(rest) >= 2 and rest[1] == "nodaemon":
    import signal
    sock_env = os.environ.get("ADB_SERVER_SOCKET", "")
    srv = None
    if sock_env.startswith("localfilesystem:"):
        sock_path = sock_env[len("localfilesystem:"):]
        try:
            os.unlink(sock_path)
        except FileNotFoundError:
            pass
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        srv.bind(sock_path)
        srv.listen(16)
    elif port is not None:
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(("127.0.0.1", int(port)))
        srv.listen(16)
    running = [True]
    def stop_handler(_sig, _frm):
        running[0] = False
        if srv is not None:
            try:
                srv.close()
            except Exception:
                pass
        sys.exit(0)
    signal.signal(signal.SIGTERM, stop_handler)
    signal.signal(signal.SIGINT, stop_handler)
    while running[0]:
        try:
            conn, _ = srv.accept()
            conn.close()
        except Exception:
            if not running[0]:
                break
    sys.exit(0)
if rest[0] == "start-server":
    sys.exit(0)
if rest[0] == "kill-server":
    sys.exit(0)
if rest[0] == "connect" and len(rest) >= 2:
    target = rest[1]
    host, p = target.rsplit(":", 1)
    try:
        s = socket.create_connection((host, int(p)), timeout=5)
        s.sendall(b"CNXN\\n")
        s.recv(64)
        s.close()
        with open(os.path.join(state_dir, "state"), "w") as f:
            f.write("device")
    except Exception:
        pass
    print(f"connected to {target}")
    sys.exit(0)
if rest[0] == "disconnect":
    try:
        os.remove(os.path.join(state_dir, "state"))
    except FileNotFoundError:
        pass
    print("disconnected")
    sys.exit(0)
if len(rest) >= 3 and rest[0] == "-s" and rest[2] == "get-state":
    st_file = os.path.join(state_dir, "state")
    if os.path.exists(st_file):
        print(open(st_file).read().strip())
        sys.exit(0)
    sys.stderr.write(f"error: device '{rest[1]}' not found\\n")
    sys.exit(1)
if len(rest) >= 3 and rest[0] == "-s" and rest[2] == "shell":
    cmd = " ".join(rest[3:])
    if "getprop service.adb.tcp.port" in cmd:
        print("boot-1\\n5555")
    sys.exit(0)
if rest[0] == "devices":
    print("List of devices attached")
    sys.exit(0)
sys.exit(0)
`;
  writeFileSync(join(dir, "adb"), py, { mode: 0o755 });
  chmodSync(join(dir, "adb"), 0o755);
  mkdirSync(stateDir, { recursive: true });
}

test("ADB / Phone device tools closed loop: device_list, device_use card approval, phone_send transfer, and unauthorized refusal", { skip: skipAdb }, async () => {
  const WS = "w-adb-parity";
  const [data, app, bin, adbState, work1, work2] = [
    fresh("adbd"),
    fresh("adba"),
    fresh("adbb"),
    fresh("adbs"),
    fresh("w1"),
    fresh("w2"),
  ];
  writeFileSync(join(app, "BUILD"), "10400\n");
  installFakeAdb(bin, adbState);

  const id = stationId(data);
  const meshPort = await freeUdpPort();
  const grantKey = new GrantKey();

  mkdirSync(join(data, "mesh"), { recursive: true });
  writeFileSync(
    join(data, "mesh", "cloud.json"),
    JSON.stringify({
      origin: "http://127.0.0.1:9",
      station: id,
      workspace: WS,
      workspace_name: "PhoneTeam",
      name: "here",
      relay_url: "",
      relay_urls: [],
      grant_keys: { keys: [grantKey.jwk] },
      peers: [],
      revocations: [],
    }),
  );

  // Two sessions: s1 (owned by pat@example.com) and s2 (another chat without phone grant).
  const s = openStore(data);
  s.insertSession({
    key: "s1",
    connect: "chat",
    runtime: "claude",
    profile: "cc",
    workspace: work1,
    token: "t-s1",
    createdBy: "pat@example.com",
    ws: WS,
    createdAt: Date.now(),
    lastActiveAt: Date.now(),
  } as never);
  const th1 = s.openThread("chat", "CHAT", "1795200000.001000", "phone test chat", "pat@example.com").id;
  s.joinThread(th1, "s1", "chat");

  s.insertSession({
    key: "s2",
    connect: "chat",
    runtime: "claude",
    profile: "cc",
    workspace: work2,
    token: "t-s2",
    createdBy: "other@example.com",
    ws: WS,
    createdAt: Date.now(),
    lastActiveAt: Date.now(),
  } as never);
  const th2 = s.openThread("chat", "CHAT", "1795200000.002000", "unauth chat", "other@example.com").id;
  s.joinThread(th2, "s2", "chat");
  s.close();

  const st = await launch(data, app, {
    PATH: bin,
    FAKE_ADB_DIR: adbState,
    STILLFAIL_LOCAL_ADMIN: "1",
    STILLFAIL_MESH_BIND_ADDR: `127.0.0.1:${meshPort}`,
  });
  await st.next("ready", (m) => m.ready === true);
  const door = (await st.next("mcp", (m) => m.serving === "mcp")).port as number;

  // Connect fake Android phone as member `pat@example.com` over loopback mesh.
  const phoneClient = await addon!.bind({
    secretKey: randomBytes(32),
    alpns: [Buffer.from("client/1")],
    relayUrls: [],
    discovery: false,
    bindAddr: "127.0.0.1:0",
  });
  cleanups.push(() => phoneClient.close());

  const now = Math.floor(Date.now() / 1000);
  const cred = grantKey.credential(
    { typ: "stillfail-member+jwt" },
    { iss: "stillfail-cloud", sub: "pat", email: "pat@example.com", name: "Pat", ws: WS, role: "owner", device: phoneClient.id(), sid: "s-phone", iat: now, exp: now + 3600 },
  );
  const conn = await given("phone connects to station over mesh", () =>
    phoneClient.connect({ id, ips: [`127.0.0.1:${meshPort}`] }, Buffer.from("stillfail/admin/1")),
  );
  assert.equal((await member(conn, cred)).ok, true);

  // Background accept loop on the phone connection: handles both ADB TCP tunnels and `phone_send` fetch requests.
  const fetched: any[] = [];
  let acceptAlive = true;
  cleanups.push(() => {
    acceptAlive = false;
  });
  void (async () => {
    while (acceptAlive) {
      let incoming: MeshStream | null = null;
      try {
        incoming = await conn.acceptBi();
      } catch {
        break;
      }
      if (!incoming) break;
      const stream = incoming;
      void (async () => {
        try {
          const reader = new Reader(stream);
          const head = await reader.line();
          if (head && typeof head === "object" && head.fetch) {
            fetched.push(head.fetch);
            const size = Number(head.fetch.size ?? 0);
            const name = String(head.fetch.name ?? "file");
            await writeLine(stream, { at: size });
            await writeLine(stream, { path: `/data/user/0/fail.still.app/files/${name}` });
            await stream.finish();
          } else {
            // ADB TCP tunnel dialled by fake adb connect (`{"tunnel": "connect"}`)
            await writeLine(stream, { ok: true });
            await stream.write(Buffer.from("CNXN-OK\n"));
            await stream.finish();
          }
        } catch {}
      })();
    }
  })();

  // Offer the phone via POST /admin/api/adb { op: "share" } (keep stream open while phone is lent).
  const phoneId = randomBytes(16).toString("hex");
  const shareStream = await conn.openBi();
  cleanups.push(() => {
    try {
      void shareStream.finish();
    } catch {}
  });
  await writeLine(shareStream, {
    method: "POST",
    path: "/admin/api/adb",
    headers: { "content-type": "application/json" },
    adb: { op: "share", phone: phoneId, device: "Pixel-Fake", model: "Pixel 9" },
  });
  const shareReader = new Reader(shareStream);
  const shareHead = await shareReader.line();
  assert.equal(shareHead.status, 200, JSON.stringify(shareHead));
  // Drain status lines in background so the station never stalls writing share updates.
  void (async () => {
    try {
      while (acceptAlive) {
        const l = await shareReader.line();
        if (l === null) break;
      }
    } catch {}
  })();

  // Helper to call /admin/api/adb control ops (decide / grants / revoke) on the member connection.
  const adbOp = async (adb: Record<string, unknown>) => {
    const stream = await conn.openBi();
    await writeLine(stream, { method: "POST", path: "/admin/api/adb", headers: { "content-type": "application/json" }, adb });
    await stream.finish();
    const r = new Reader(stream);
    const h = await r.line();
    return [h.status as number, JSON.parse((await r.rest()).toString() || "null")];
  };

  // 1) device_list shows the lent phone.
  const listRes = await given("device_list shows Pixel-Fake", async () => {
    const r = await tool(door, "t-s1", "device_list", {});
    return !r.error && r.text.includes("Pixel-Fake") ? r : null;
  });
  assert.match(listRes.text, /Pixel-Fake/);
  assert.match(listRes.text, /adb/i);

  // 2) Unauthorized session s2 calling phone_send before any grant is refused.
  writeFileSync(join(work2, "unauth.apk"), "not allowed");
  const unauthSend = await tool(door, "t-s2", "phone_send", { path: "unauth.apk" });
  assert.match(unauthSend.text, /holds no phone grant|ask for the phone/i);

  // 3) s1 calls device_use for the phone -> approval card posted in s1's chat.
  const useAsk = await tool(door, "t-s1", "device_use", { device: "Pat 的 Pixel-Fake", reason: "install parity apk" });
  assert.equal(useAsk.error, false, useAsk.text);

  const db = new DatabaseSync(join(data, "stillfail.db"), { readOnly: true });
  let grantId = "";
  try {
    const row = await given("adb_requests pending row created", () =>
      db.prepare("SELECT id, status FROM adb_requests WHERE session = 's1' AND status = 'pending'").get() as
        | { id: string; status: string }
        | undefined,
    );
    grantId = row.id;
  } finally {
    db.close();
  }

  // 4) Owner approves phone grant via /admin/api/adb { op: "decide", request, scope: "hour" }.
  const [decStatus, decBody] = await adbOp({ op: "decide", request: grantId, scope: "hour" });
  assert.equal(decStatus, 200, JSON.stringify(decBody));
  assert.equal(decBody.request.status, "granted");

  // 5) s1 calls device_use again -> receives granted adb server (-P <port> -s <serial>).
  const useGranted = await tool(door, "t-s1", "device_use", { device: "Pat 的 Pixel-Fake", reason: "install parity apk" });
  assert.equal(useGranted.error, false, useGranted.text);
  assert.match(useGranted.text, /Granted\./);
  assert.match(useGranted.text, /adb -P \d+ -s 127\.0\.0\.1:\d+/);

  // 6) s1 calls phone_send -> file staged in workspace uploads and fetched by phone over mesh.
  const apkPayload = "FAKE-APK-BINARY-CONTENT-12345";
  writeFileSync(join(work1, "demo.apk"), apkPayload);
  const sendRes = await tool(door, "t-s1", "phone_send", { path: "demo.apk" });
  assert.equal(sendRes.error, false, sendRes.text);
  assert.match(sendRes.text, /On the phone at \/data\/user\/0\/fail\.still\.app\/files\/[0-9a-f]{16}-demo\.apk/);
  assert.equal(fetched.length, 1);
  assert.equal(fetched[0].size, apkPayload.length);
  const stagedPath = join(work1, "uploads", fetched[0].name);
  assert.equal(readFileSync(stagedPath, "utf8"), apkPayload);

  // 7) Unauthorized session s2 is STILL refused phone_send even while s1 holds a grant.
  const unauthSend2 = await tool(door, "t-s2", "phone_send", { path: "unauth.apk" });
  assert.match(unauthSend2.text, /holds no phone grant|ask for the phone/i);

  // 8) s1 hands back the phone (`done: true`) -> subsequent phone_send is refused.
  const doneRes = await tool(door, "t-s1", "device_use", { device: "Pat 的 Pixel-Fake", done: true });
  assert.equal(doneRes.error, false, doneRes.text);
  const sendAfterDone = await tool(door, "t-s1", "phone_send", { path: "demo.apk" });
  assert.match(sendAfterDone.text, /holds no phone grant|ask for the phone/i);

  assert.doesNotMatch(st.err(), /SQLITE_BUSY|database is locked|unknown op/i);
  await st.stop();
  assert.equal(await st.ended, 0, st.err());
});

// ═══════════════════════════════════════════════════════════════════════════════
// 3. Multi-Runtime Drivers real-process closed loop (claude + codex + agy)
// ═══════════════════════════════════════════════════════════════════════════════

function installFakeDrivers(dir: string): void {
  makeNoNodeBin(dir);

  // Fake `claude` (pure /bin/sh + curl, no Node)
  const fakeClaude = String.raw`#!/bin/sh
case " $* " in *" -p "*) ;; *) printf 'claude 2.1.0\n'; exit 0 ;; esac
sid=""; cfg=""
while [ $# -gt 0 ]; do
  case "$1" in
    --session-id|--resume) sid="$2"; shift ;;
    --mcp-config) cfg="$2"; shift ;;
  esac
  shift
done
url=$(printf '%s' "$cfg" | sed -n 's/.*"url":"\([^"]*\)".*/\1/p')
printf '{"runtime":"claude","pid":%s,"sid":"%s"}\n' "$$" "$sid" >> "$FAKE_OUT/launches.jsonl"
say() { printf '%s\n' "$1"; }
# chat_post holds a post back while the steer is still unread; send the held one again until it goes.
mcp_post() {
  held_id=""
  i=0
  while [ "$i" -lt 200 ]; do
    i=$((i + 1))
    if [ -n "$held_id" ]; then
      args='{"to":"'"$1"'","send":"'"$held_id"'","kind":"all_done","done":"'"$3"'"}'
    else
      args='{"to":"'"$1"'","text":"'"$2"'","kind":"all_done","done":"'"$3"'"}'
    fi
    resp=$(curl -sS --max-time 10 -X POST "$url" -H 'content-type: application/json' -H "authorization: Bearer $STILLFAIL_MCP_TOKEN" \
      -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"chat_post","arguments":'"$args"'}}' 2>>"$FAKE_OUT/claude-mcp-err.log")
    case "$resp" in
      *'Posted to'*) return 0 ;;
      *'Not posted:'*) held_id=$(printf '%s' "$resp" | sed -n 's/.*Held as \(held-[0-9][0-9]*\).*/\1/p') ;;
      *'no held post'*) held_id="" ;;
      *) printf '%s\n' "$resp" >> "$FAKE_OUT/claude-mcp-err.log" ;;
    esac
    sleep 0.05
  done
  return 1
}
while IFS= read -r line; do
  case "$line" in *'"type":"user"'*) ;; *) continue ;; esac
  to=$(printf '%s' "$line" | sed -n 's/.*thread=\\"\([^\\]*\)\\".*/\1/p')
  if [ -n "$to" ]; then printf '%s' "$to" > "$FAKE_OUT/claude-to-$sid"; else to=$(cat "$FAKE_OUT/claude-to-$sid" 2>/dev/null); fi
  say '{"type":"system","subtype":"init","session_id":"'"$sid"'","model":"claude-sonnet-4-6","tools":[],"mcp_servers":[]}'
  say '{"type":"system","subtype":"status","status":"requesting","session_id":"'"$sid"'"}'
  case "$line" in
    *SCENARIO-STEER*)
      : > "$FAKE_OUT/claude-steer-ready"
      while IFS= read -r sline; do
        case "$sline" in
          *'"type":"user"'*)
            printf '%s\n' "$sline" >> "$FAKE_OUT/claude-steered.jsonl"
            say '{"type":"system","subtype":"status","status":"requesting","session_id":"'"$sid"'"}'
            say '{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"ack1","name":"STEER-ACK"}},"session_id":"'"$sid"'"}'
            mcp_post "$to" "claude-steered-ok" "answered steered turn"
            break ;;
        esac
      done
      say '{"type":"result","subtype":"success","is_error":false,"duration_ms":1,"num_turns":1,"session_id":"'"$sid"'","result":"ok"}'
      continue ;;
    *SCENARIO-STOP*)
      : > "$FAKE_OUT/claude-stop-ready"
      while IFS= read -r iline; do
        case "$iline" in
          *'"subtype":"interrupt"'*)
            req_id=$(printf '%s' "$iline" | sed -n 's/.*"request_id":"\([^"]*\)".*/\1/p')
            say '{"type":"control_response","response":{"subtype":"success","request_id":"'"$req_id"'"}}'
            break ;;
        esac
      done
      say '{"type":"result","subtype":"error_during_execution","is_error":true,"duration_ms":1,"num_turns":1,"session_id":"'"$sid"'","result":"interrupted"}'
      continue ;;
    *SCENARIO-CRASH*)
      : > "$FAKE_OUT/claude-crashed"
      exit 4 ;;
    *RECOVER-AFTER-CRASH*)
      mcp_post "$to" "claude-recovered-pid-$$" "recovered after crash"
      say '{"type":"result","subtype":"success","is_error":false,"duration_ms":1,"num_turns":1,"session_id":"'"$sid"'","result":"ok"}'
      continue ;;
  esac
  mcp_post "$to" "claude-reply-pid-$$" "answered turn"
  say '{"type":"result","subtype":"success","is_error":false,"duration_ms":1,"num_turns":1,"session_id":"'"$sid"'","result":"ok"}'
done
`;
  writeFileSync(join(dir, "claude"), fakeClaude, { mode: 0o755 });
  chmodSync(join(dir, "claude"), 0o755);

  // Fake `codex` (pure python3, no Node) speaking `codex app-server --listen stdio://` JSON-RPC
  const fakeCodex = `#!/usr/bin/env python3
import json, os, re, sys, threading, time, urllib.request

args = sys.argv[1:]
if args and args[0] == "--version":
    print("codex-cli 0.50.0", flush=True)
    sys.exit(0)

out_dir = os.environ["FAKE_OUT"]
with open(os.path.join(out_dir, "launches.jsonl"), "a") as f:
    f.write(json.dumps({"runtime": "codex", "pid": os.getpid(), "argv": args}) + "\\n")

lock = threading.Lock()
def say(obj):
    with lock:
        sys.stdout.write(json.dumps(obj) + "\\n")
        sys.stdout.flush()

def notify(method, params):
    say({"method": method, "params": params})

def mcp_post(mcp_url, token, to, text, done):
    # chat_post holds a post back while the steer is still unread; send the held one again until it goes.
    held_id = None
    for _ in range(200):
        args = {"to": to, "send": held_id, "kind": "all_done", "done": done} if held_id else {"to": to, "text": text, "kind": "all_done", "done": done}
        body = json.dumps({
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": {"name": "chat_post", "arguments": args},
        }).encode()
        req = urllib.request.Request(mcp_url, data=body, headers={"content-type": "application/json", "authorization": f"Bearer {token}"})
        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                resp = r.read().decode("utf-8", "replace")
        except Exception as e:
            resp = "error: " + str(e)
        if "Posted to" in resp:
            return
        if "Not posted:" in resp:
            m = re.search(r"Held as (held-\\d+)", resp)
            held_id = m.group(1) if m else None
        elif "no held post" in resp:
            held_id = None
        else:
            with open(os.path.join(out_dir, "codex-mcp-err.log"), "a") as f:
                f.write(resp + "\\n")
        time.sleep(0.05)

seq = 0
threads = {}

def get_thread(tid):
    if tid not in threads:
        threads[tid] = {"turn": None, "interrupted": False, "steers": [], "ev": threading.Event(), "url": "", "token": "", "to": ""}
    return threads[tid]

def run_turn(tid, text):
    global seq
    t = get_thread(tid)
    t["interrupted"] = False
    t["ev"].clear()
    turn_id = t["turn"]
    m = re.search(r'thread="([^"]+)"', text)
    if m:
        t["to"] = m.group(1)
    notify("turn/started", {"threadId": tid, "turn": {"id": turn_id, "status": "inProgress", "items": []}})
    seq += 1
    item_id = f"it-{seq}"
    notify("item/started", {"threadId": tid, "turnId": turn_id, "item": {"type": "agentMessage", "id": item_id, "text": ""}})

    if "SCENARIO-CRASH" in text:
        with open(os.path.join(out_dir, "codex-crashed"), "w") as f:
            f.write("1")
        notify("item/agentMessage/delta", {"threadId": tid, "turnId": turn_id, "itemId": item_id, "delta": "partial"})
        os._exit(4)

    if "SCENARIO-STEER" in text:
        with open(os.path.join(out_dir, "codex-steer-ready"), "w") as f:
            f.write("1")
        while not t["steers"] and not t["interrupted"]:
            t["ev"].wait(0.05)
            t["ev"].clear()
        if t["steers"]:
            steered_text = " ".join(t["steers"])
            t["steers"].clear()
            with open(os.path.join(out_dir, "codex-steered.jsonl"), "a") as f:
                f.write(json.dumps({"text": steered_text}) + "\\n")
            seq += 1
            cmd_id = f"cmd-{seq}"
            notify("item/started", {"threadId": tid, "turnId": turn_id, "item": {"type": "commandExecution", "id": cmd_id, "command": "true"}})
            notify("item/completed", {"threadId": tid, "turnId": turn_id, "item": {"type": "commandExecution", "id": cmd_id}})
            notify("item/agentMessage/delta", {"threadId": tid, "turnId": turn_id, "itemId": item_id, "delta": "codex-steered"})
            if t["url"] and t["to"]:
                mcp_post(t["url"], t["token"], t["to"], "codex-steered-ok", "answered steered turn")
    elif "SCENARIO-STOP" in text:
        with open(os.path.join(out_dir, "codex-stop-ready"), "w") as f:
            f.write("1")
        while not t["interrupted"]:
            t["ev"].wait(0.05)
            t["ev"].clear()
    elif "RECOVER-AFTER-CRASH" in text:
        if t["url"] and t["to"]:
            mcp_post(t["url"], t["token"], t["to"], f"codex-recovered-pid-{os.getpid()}", "recovered after crash")
    else:
        if t["url"] and t["to"]:
            mcp_post(t["url"], t["token"], t["to"], f"codex-reply-pid-{os.getpid()}", "answered turn")

    notify("item/completed", {"threadId": tid, "turnId": turn_id, "item": {"type": "agentMessage", "id": item_id}})
    status = "interrupted" if t["interrupted"] else "completed"
    t["turn"] = None
    notify("turn/completed", {"threadId": tid, "turn": {"id": turn_id, "status": status, "items": []}})

for raw in sys.stdin:
    raw = raw.strip()
    if not raw:
        continue
    msg = json.loads(raw)
    mid = msg.get("id")
    method = msg.get("method")
    params = msg.get("params") or {}
    if method == "initialize":
        say({"id": mid, "result": {"userAgent": "fake-codex/0.50.0 (fake)"}})
    elif method == "initialized":
        continue
    elif method in ("thread/start", "thread/resume"):
        seq += 1
        tid = params.get("threadId") or f"th-{seq}"
        t = get_thread(tid)
        cfg = params.get("config") or {}
        if isinstance(cfg.get("mcp_servers.stillfail.url"), str):
            t["url"] = cfg["mcp_servers.stillfail.url"]
        hdrs = cfg.get("mcp_servers.stillfail.http_headers") or {}
        auth = hdrs.get("Authorization") or hdrs.get("authorization") or ""
        if isinstance(auth, str) and auth.startswith("Bearer "):
            t["token"] = auth[7:]
        else:
            env_var = cfg.get("mcp_servers.stillfail.bearer_token_env_var") or "STILLFAIL_MCP_TOKEN"
            t["token"] = os.environ.get(env_var, os.environ.get("STILLFAIL_MCP_TOKEN", ""))
        say({"id": mid, "result": {"thread": {"id": tid}}})
    elif method == "thread/read":
        say({"id": mid, "result": {"thread": {"id": params.get("threadId")}}})
    elif method == "turn/start":
        tid = params["threadId"]
        t = get_thread(tid)
        seq += 1
        t["turn"] = f"tu-{seq}"
        say({"id": mid, "result": {"turn": {"id": t["turn"], "status": "inProgress", "items": []}}})
        text = "".join(i.get("text", "") for i in params.get("input", []))
        threading.Thread(target=run_turn, args=(tid, text), daemon=True).start()
    elif method == "turn/steer":
        tid = params["threadId"]
        t = get_thread(tid)
        if not t["turn"] or t["turn"] != params.get("expectedTurnId"):
            say({"id": mid, "error": {"code": -32600, "message": "no active turn to steer"}})
        else:
            t["steers"].append("".join(i.get("text", "") for i in params.get("input", [])))
            t["ev"].set()
            say({"id": mid, "result": {"turnId": t["turn"]}})
    elif method == "turn/interrupt":
        tid = params["threadId"]
        t = get_thread(tid)
        t["interrupted"] = True
        t["ev"].set()
        say({"id": mid, "result": {}})
    elif method == "thread/unsubscribe":
        say({"id": mid, "result": {"status": "unsubscribed"}})
    elif method == "mcpServerStatus/list":
        tid = params.get("threadId")
        data_list = [] if tid is None else [{"name": "stillfail", "runtimeStatus": "connected", "tools": {}}]
        say({"id": mid, "result": {"data": data_list, "nextCursor": None}})
    elif method == "model/list":
        say({"id": mid, "result": {"data": [{"id": "gpt-6.2-sol", "supportedReasoningEfforts": [{"reasoningEffort": "medium"}, {"reasoningEffort": "high"}]}], "nextCursor": None}})
    elif mid is not None:
        say({"id": mid, "result": {}})
`;
  writeFileSync(join(dir, "codex"), fakeCodex, { mode: 0o755 });
  chmodSync(join(dir, "codex"), 0o755);

  // Fake `agy` (pure python3, no Node) speaking `agy acp --gemini-dir ...` JSON-RPC
  const fakeAgy = `#!/usr/bin/env python3
import json, os, re, sys, time, urllib.request, uuid

args = sys.argv[1:]
out_dir = os.environ["FAKE_OUT"]
with open(os.path.join(out_dir, "launches.jsonl"), "a") as f:
    f.write(json.dumps({"runtime": "agy", "pid": os.getpid(), "argv": args}) + "\\n")

if not args or args[0] != "acp":
    print("gemini-3.5-flash", flush=True)
    sys.exit(0)

gemini_dir = args[args.index("--gemini-dir") + 1] if "--gemini-dir" in args else out_dir
conv_dir = os.path.join(gemini_dir, "antigravity-cli", "conversations")
os.makedirs(conv_dir, exist_ok=True)

def say(obj):
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", **obj}) + "\\n")
    sys.stdout.flush()

def mcp_post(mcp_url, token, to, text, done):
    # chat_post holds a post back while the steer is still unread; send the held one again until it goes.
    held_id = None
    for _ in range(200):
        args = {"to": to, "send": held_id, "kind": "all_done", "done": done} if held_id else {"to": to, "text": text, "kind": "all_done", "done": done}
        body = json.dumps({
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": {"name": "chat_post", "arguments": args},
        }).encode()
        req = urllib.request.Request(mcp_url, data=body, headers={"content-type": "application/json", "authorization": f"Bearer {token}"})
        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                resp = r.read().decode("utf-8", "replace")
        except Exception as e:
            resp = "error: " + str(e)
        if "Posted to" in resp:
            return
        if "Not posted:" in resp:
            m = re.search(r"Held as (held-\\d+)", resp)
            held_id = m.group(1) if m else None
        elif "no held post" in resp:
            held_id = None
        else:
            with open(os.path.join(out_dir, "agy-mcp-err.log"), "a") as f:
                f.write(resp + "\\n")
        time.sleep(0.05)

models = {
    "currentModelId": "gemini-3.5-flash",
    "availableModels": [
        {"modelId": "gemini-3.5-flash", "name": "Gemini 3.5 Flash"},
        {"modelId": "gemini-3.1-pro", "name": "Gemini 3.1 Pro"},
    ],
}

session_id = ""
held_id = None
mcp_url = ""
mcp_token = ""
last_to = ""

def extract_mcp(params):
    global mcp_url, mcp_token
    for s in params.get("mcpServers") or []:
        if s.get("url"):
            mcp_url = s["url"]
        for h in s.get("headers") or []:
            if h.get("name", "").lower() == "authorization" and h.get("value", "").startswith("Bearer "):
                mcp_token = h["value"][7:]

for raw in sys.stdin:
    raw = raw.strip()
    if not raw:
        continue
    m = json.loads(raw)
    mid = m.get("id")
    method = m.get("method")
    p = m.get("params") or {}
    if method == "initialize":
        say({"id": mid, "result": {
            "protocolVersion": 1,
            "agentCapabilities": {"loadSession": True, "_meta": {"antigravity": {"tier": True, "systemPrompt": {"append": True}}}},
            "agentInfo": {"name": "Antigravity ACP Server", "version": "1.5.9"},
        }})
    elif method == "session/new":
        extract_mcp(p)
        session_id = str(uuid.uuid4())
        with open(os.path.join(conv_dir, f"{session_id}.db"), "w") as f:
            f.write("conversation")
        say({"id": mid, "result": {"sessionId": session_id, "models": models}})
    elif method == "session/load":
        extract_mcp(p)
        session_id = p["sessionId"]
        say({"id": mid, "result": {"models": models}})
    elif method == "session/set_model":
        say({"id": mid, "result": {}})
    elif method == "session/cancel":
        if held_id is not None:
            say({"id": held_id, "result": {"stopReason": "cancelled"}})
            held_id = None
    elif method == "session/prompt":
        text = p["prompt"][0]["text"]
        tm = re.search(r'thread="([^"]+)"', text)
        if tm:
            last_to = tm.group(1)
        prev = held_id
        held_id = mid
        if prev is not None:
            # Steered while a previous prompt was held: record steer, finish previous prompt, post ack, finish new prompt
            with open(os.path.join(out_dir, "agy-steered.jsonl"), "a") as f:
                f.write(json.dumps({"text": text}) + "\\n")
            say({"id": prev, "result": {"stopReason": "end_turn"}})
            say({"method": "session/update", "params": {"sessionId": session_id, "update": {"sessionUpdate": "user_message_chunk", "content": {"type": "text", "text": text}}}})
            say({"method": "session/update", "params": {"sessionId": session_id, "update": {"sessionUpdate": "tool_call", "toolCallId": "st1", "title": "ack", "kind": "read", "status": "in_progress"}}})
            say({"method": "session/update", "params": {"sessionId": session_id, "update": {"sessionUpdate": "tool_call_update", "toolCallId": "st1", "status": "completed", "content": []}}})
            if mcp_url and last_to:
                mcp_post(mcp_url, mcp_token, last_to, "agy-steered-ok", "answered steered turn")
            say({"id": mid, "result": {"stopReason": "end_turn"}})
            held_id = None
            continue
        if "SCENARIO-CRASH" in text:
            with open(os.path.join(out_dir, "agy-crashed"), "w") as f:
                f.write("1")
            os._exit(4)
        if "SCENARIO-STEER" in text:
            with open(os.path.join(out_dir, "agy-steer-ready"), "w") as f:
                f.write("1")
            say({"method": "session/update", "params": {"sessionId": session_id, "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "working..."}}}})
            continue
        if "SCENARIO-STOP" in text:
            with open(os.path.join(out_dir, "agy-stop-ready"), "w") as f:
                f.write("1")
            say({"method": "session/update", "params": {"sessionId": session_id, "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "waiting..."}}}})
            continue
        if "RECOVER-AFTER-CRASH" in text:
            if mcp_url and last_to:
                mcp_post(mcp_url, mcp_token, last_to, f"agy-recovered-pid-{os.getpid()}", "recovered after crash")
            say({"id": mid, "result": {"stopReason": "end_turn"}})
            held_id = None
            continue
        if mcp_url and last_to:
            mcp_post(mcp_url, mcp_token, last_to, f"agy-reply-pid-{os.getpid()}", "answered turn")
        say({"id": mid, "result": {"stopReason": "end_turn"}})
        held_id = None
    elif mid is not None:
        say({"id": mid, "error": {"code": -32601, "message": f"Method not found: {method}"}})
`;
  writeFileSync(join(dir, "agy"), fakeAgy, { mode: 0o755 });
  chmodSync(join(dir, "agy"), 0o755);
}

test("Multi-runtime drivers real-process closed loop (claude, codex, agy): running steer, stop/interrupt, and crash recovery", { skip: skipDrivers }, async () => {
  const [data, app, bin, out] = [fresh("drvd"), fresh("drva"), fresh("drvb"), fresh("drvo")];
  writeFileSync(join(app, "BUILD"), "10400\n");
  installFakeDrivers(bin);

  for (const h of ["cc", "cx", "ag"]) mkdirSync(join(data, "homes", h), { recursive: true });
  writeFileSync(join(data, "homes", "cc", ".credentials.json"), "{}");
  writeFileSync(
    join(data, "config.json"),
    JSON.stringify({
      profiles: [
        { id: "cc", runtime: "claude", home: "homes/cc", access: { kind: "anthropic-api", key: "sk-test" }, models: ["claude-sonnet-4-6"] },
        { id: "cx", runtime: "codex", home: "homes/cx", access: { kind: "opencode-go", key: "k-test" }, models: ["gpt-6.2-sol"] },
        { id: "ag", runtime: "agy", home: "homes/ag", access: { kind: "api-provider", provider: "google", key: "gemini-key" }, models: ["gemini-3.5-flash"] },
      ],
      maxNudges: 0,
    }),
  );
  mkdirSync(join(data, "mesh"), { recursive: true });
  writeFileSync(
    join(data, "mesh", "cloud.json"),
    JSON.stringify({ origin: "http://127.0.0.1:9", workspace: "w1", workspace_name: "Drivers", station: "st-drv", name: "here" }),
  );

  // Pre-seed one session per runtime: claude, codex, agy.
  const store = openStore(data);
  const runtimes = [
    { rt: "claude", key: "chat:drv-claude", profile: "cc", model: "claude-sonnet-4-6", token: "t-cc", ts: "1795300000.001000" },
    { rt: "codex", key: "chat:drv-codex", profile: "cx", model: "gpt-6.2-sol", token: "t-cx", ts: "1795300000.002000" },
    { rt: "agy", key: "chat:drv-agy", profile: "ag", model: "gemini-3.5-flash", token: "t-ag", ts: "1795300000.003000" },
  ] as const;
  const threads: Record<string, number> = {};
  for (const r of runtimes) {
    const wsDir = join(data, "sessions", "chat", r.key.slice(5), "workspace");
    mkdirSync(wsDir, { recursive: true });
    store.insertSession({
      key: r.key,
      connect: "ember",
      runtime: r.rt,
      profile: r.profile,
      model: r.model,
      createdBy: "ada@x.com",
      workspace: wsDir,
      token: r.token,
      createdAt: Date.now(),
      lastActiveAt: Date.now(),
      title: `driver ${r.rt}`,
      ws: "w1",
    } as never);
    const th = store.openThreadOf("ember", "CHAT", r.ts, `driver ${r.rt}`, "ada@x.com", r.key);
    store.joinThread(th.id, r.key, "ember");
    threads[r.rt] = th.id;
  }
  store.close();

  const st = await launch(data, app, {
    PATH: bin,
    HOME: data,
    STILLFAIL_RUNNER: runner,
    STILLFAIL_AGENT_NICE: "0",
    STILLFAIL_LOCAL_ADMIN: "1",
    FAKE_OUT: out,
  });
  await st.next("ready", (m) => m.ready === true);
  const door = (await st.next("mcp", (m) => m.serving === "mcp")).port as number;

  const sendMsg = async (threadId: number, text: string) => {
    const res = await httpJson(door, `/admin-api/threads/${threadId}/messages`, "POST", { text });
    assert.equal(res.status, 200, `send message to thread ${threadId}: ${res.raw}`);
  };

  const launchesOf = (rt: string): { pid: number }[] => {
    const p = join(out, "launches.jsonl");
    if (!existsSync(p)) return [];
    return readFileSync(p, "utf8")
      .trim()
      .split("\n")
      .filter(Boolean)
      .map((l) => JSON.parse(l))
      .filter((x) => x.runtime === rt);
  };

  const hasAgentMessage = (threadId: number, pattern: RegExp): boolean => {
    const db = new DatabaseSync(join(data, "stillfail.db"), { readOnly: true });
    try {
      const rows = db
        .prepare("SELECT text FROM entries WHERE thread = ? AND kind = 'message' AND author_kind = 'agent'")
        .all(threadId) as { text: string }[];
      return rows.some((r) => pattern.test(r.text ?? ""));
    } finally {
      db.close();
    }
  };

  const sessionRunning = async (key: string): Promise<boolean> => {
    const res = await httpJson(door, `/admin-api/sessions/${encodeURIComponent(key)}`);
    if (res.status !== 200) return false;
    return res.json?.running === true || res.json?.session?.running === true;
  };

  for (const { rt, key } of runtimes) {
    const thId = threads[rt]!;

    // A) Running steer without dropping messages (#7585 / #7597)
    await sendMsg(thId, `SCENARIO-STEER-${rt}`);
    await given(`${rt} enters steer wait`, () => existsSync(join(out, `${rt}-steer-ready`)), 25_000);
    await sendMsg(thId, `STEER-PAYLOAD-${rt}`);
    await given(`${rt} received steered message`, () => {
      const p = join(out, `${rt}-steered.jsonl`);
      return existsSync(p) && readFileSync(p, "utf8").includes(`STEER-PAYLOAD-${rt}`);
    }, 25_000);
    await given(`${rt} posted steered reply`, () => hasAgentMessage(thId, new RegExp(`${rt}-steered-ok`)), 25_000);
    await given(`${rt} idle after steer`, async () => !(await sessionRunning(key)), 20_000);

    // B) Running stop / interrupt -> returns to idle -> next message works
    await sendMsg(thId, `SCENARIO-STOP-${rt}`);
    await given(`${rt} enters stop wait`, () => existsSync(join(out, `${rt}-stop-ready`)), 25_000);
    const stopRes = await httpJson(door, `/admin-api/sessions/${encodeURIComponent(key)}/stop`, "POST", {});
    assert.equal(stopRes.status, 200, `${rt} stop failed: ${stopRes.raw}`);
    await given(`${rt} idle after stop`, async () => !(await sessionRunning(key)), 20_000);

    // C) Process crash mid-turn -> error reported -> next turn spawns fresh process (recovery/reset)
    const pidsBeforeCrash = new Set(launchesOf(rt).map((x) => x.pid));
    await sendMsg(thId, `SCENARIO-CRASH-${rt}`);
    await given(`${rt} crashed mid-turn`, () => existsSync(join(out, `${rt}-crashed`)), 25_000);
    await given(`${rt} idle after crash`, async () => !(await sessionRunning(key)), 25_000);

    // Next turn launches a fresh process (new PID) and completes cleanly.
    await sendMsg(thId, `RECOVER-AFTER-CRASH-${rt}`);
    await given(`${rt} recovered with fresh process and posted reply`, () => {
      const pidsAfter = launchesOf(rt).map((x) => x.pid);
      const hasNewPid = pidsAfter.some((pid) => !pidsBeforeCrash.has(pid));
      return hasNewPid && hasAgentMessage(thId, new RegExp(`${rt}-recovered-pid-\\d+`));
    }, 30_000);
    await given(`${rt} idle after recovery`, async () => !(await sessionRunning(key)), 20_000);
  }

  assert.doesNotMatch(st.err(), /SQLITE_BUSY|database is locked|unknown op/i);
  await st.stop();
  assert.equal(await st.ended, 0, st.err());
});
