// Gate 12 Cross-Engine Real-Machine E2E for `stillfail-station-pion` (`roles:rig`):
// 1. `--version` (`stillfail-station-pion 0.1.0 roles:rig commands:`), `--smoke-sys`, `--smoke-http`.
// 2. Real `stillfail-station-pion run --data <dir> --control-fd 5` on Node-generated historical `stillfail.db`
//    + rig `cloud.json`: rejects non-rig data dir, waits for previous `hub.json` PID before taking over,
//    writes new `hub.json`, reports `serving`/`ready`, `/healthz` 200, `drain` writes `run/drained` + reports
//    `drained("idle")` and exits cleanly on `stop` with `hub.json` removed.
// 3. Real owner-signed grant / revoke + remote task + `/jobs/notify` end-to-end over real iroh QUIC mesh
//    (`PEER_BYTES_ALPN`): ungranted task rejected -> signed grant -> task runs `stillfail-job notify` and
//    completes -> long-running task started -> owner revokes grant -> task immediately stopped & subsequent
//    requests refused.
// 4. Real `Node <-> Pion <-> Node` handover drill on the same data directory and historical SQLite DB:
//    Node writes historical job + signed grant -> Pion takes over, runs & persists a new job + notice, drains
//    and exits with 0 orphans -> Node reopens DB & grants losslessly.
import assert from "node:assert/strict";
import { type ChildProcess, execFileSync, spawn, spawnSync } from "node:child_process";
import { createHash, generateKeyPairSync, randomBytes, sign as nodeSign } from "node:crypto";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { request as httpRequest } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Duplex } from "node:stream";
import { after, test } from "node:test";
import { fileURLToPath } from "node:url";
import { DatabaseSync } from "node:sqlite";
import { type GrantBody, type Kind, type Timeout, latest, signedBytes } from "../../client/core-ts/src/rig-form.ts";
import { type Entry, entryHash, signedBytes as entryBytes } from "../../shared/lock.ts";
import { loadMesh, type Endpoint } from "../src/mesh/native.ts";
import { PEER_BYTES_ALPN } from "../src/mesh/peer.ts";
import { Store } from "../src/store/store.ts";

const root = fileURLToPath(new URL("../..", import.meta.url));
const sha256 = (bytes: Uint8Array) => createHash("sha256").update(bytes).digest();

const dirs: string[] = [];
const children: ChildProcess[] = [];
const endpoints: Endpoint[] = [];

function freshDir(tag: string): string {
  const dir = mkdtempSync(join(tmpdir(), `pion-rig-e2e-${tag}-`));
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

function resolveMeshAddon() {
  if (!process.env.STILLFAIL_MESH_NATIVE) {
    try {
      const target = process.platform === "darwin" ? "darwin-arm64"
        : process.arch === "arm64" ? "linux-arm64" : "linux-x64";
      const dir = execFileSync(process.execPath, [join(root, "scripts/native.ts"), "path", "mesh", target], {
        cwd: root,
        encoding: "utf8",
      }).trim();
      const candidate = join(dir, "mesh.node");
      if (existsSync(candidate)) process.env.STILLFAIL_MESH_NATIVE = candidate;
    } catch {}
  }
  try {
    return loadMesh();
  } catch {
    return null;
  }
}

function edKey() {
  const { privateKey, publicKey } = generateKeyPairSync("ed25519");
  const hex = (publicKey.export({ format: "der", type: "spki" }) as Buffer).subarray(-32).toString("hex");
  return {
    hex,
    id: `ed25519:${hex}`,
    sign: (bytes: Uint8Array) => nodeSign(null, bytes, privateKey).toString("hex"),
  };
}

function makeOwner(sub: string) {
  const first = edKey();
  const chain: Entry[] = [];
  const last = chain[chain.length - 1];
  const e = {
    v: 1,
    ws: `person:${sub}`,
    seq: 0,
    prev: last ? entryHash(last) : null,
    at: 1000,
    kind: "genesis",
    body: { sub, device: { key: first.id, id: edKey().hex, label: "owner-dev" } },
  } as Omit<Entry, "sig">;
  chain.push({
    ...e,
    sig: { key: first.id, alg: "Ed25519", sig: first.sign(entryBytes(entryHash(e as Entry))) },
  } as Entry);
  const says = <B>(kind: Kind, body: B) => ({
    body,
    sig: { key: first.id, sig: first.sign(signedBytes(kind, body, sha256)) },
  });
  return { sub, first, chain, says, genesis: () => entryHash(chain[0]!) };
}

function httpGet(port: number, path: string): Promise<{ status: number; body: string }> {
  return new Promise((resolve, reject) => {
    const req = httpRequest({ host: "127.0.0.1", port, path, method: "GET" }, (res) => {
      const chunks: Buffer[] = [];
      res.on("data", (c) => chunks.push(c));
      res.on("end", () => resolve({ status: res.statusCode ?? 0, body: Buffer.concat(chunks).toString("utf8") }));
    });
    req.on("error", reject);
    req.end();
  });
}

async function until<T>(what: string, fn: () => T | null | undefined | false | Promise<T | null | undefined | false>, ms = 15_000): Promise<T> {
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

interface RigHandle {
  child: ChildProcess;
  ctrl: Duplex;
  messages: Record<string, unknown>[];
  stderr: () => string;
  meshAddr: () => string | null;
  sendCtrl: (obj: Record<string, unknown>) => void;
  waitExit: (ms?: number) => Promise<number | null>;
}

function startPionRig(bin: string, data: string, extraArgs: string[] = []): RigHandle {
  const child = spawn(
    bin,
    ["run", "--data", data, "--port", "0", "--control-fd", "5", ...extraArgs],
    {
      stdio: ["ignore", "pipe", "pipe", "ignore", "ignore", "pipe"],
      env: {
        ...process.env,
        STILLFAIL_MESH_BIND_ADDR: "127.0.0.1:0",
        STILLFAIL_NO_DISCOVERY: "1",
        STILLFAIL_NO_DHT: "1",
      },
    },
  );
  children.push(child);
  const ctrl = child.stdio[5] as Duplex;
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
      new Promise<never>((_, rej) => setTimeout(() => rej(new Error(`rig did not exit in ${ms} ms; stderr:\n${errText}`)), ms)),
    ]),
  };
}

async function peerRpc(ep: Endpoint, rigId: string, rigAddr: string, workspace: string, request: Record<string, unknown>): Promise<any> {
  const conn = await ep.connect({ id: rigId, relays: [], ips: [rigAddr] }, PEER_BYTES_ALPN);
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
    const text = Buffer.concat(chunks).toString("utf8").trim();
    const parsed = JSON.parse(text);
    if ("error" in parsed) throw new Error(String(parsed.error));
    return parsed.result;
  } finally {
    await conn.close(0, "done");
  }
}

function seedRigDataDir(data: string, ownerGenesis: string, rigKeySeed: Buffer, rigId: string, peerId: string, ws = "ws-e2e-1") {
  mkdirSync(join(data, "mesh"), { recursive: true });
  writeFileSync(join(data, "mesh/secret.key"), rigKeySeed, { mode: 0o600 });
  writeFileSync(
    join(data, "mesh/cloud.json"),
    JSON.stringify({
      origin: "",
      station: rigId,
      workspace: ws,
      workspace_name: "E2E Rig WS",
      name: "pion-rig-e2e",
      relay_url: "",
      relay_urls: [],
      grant_keys: {},
      peers: [{ id: peerId, name: "peer-node" }],
      revocations: [],
      rig: { owner: "owner-1", owner_email: "owner@example.com", owner_name: "Owner", person: ownerGenesis },
    }),
    { mode: 0o600 },
  );
}

const bin = resolvePionBinary();

test("Gate 12.1: --version advertises roles:rig only, --smoke-sys and --smoke-http pass", () => {
  const ver = spawnSync(bin, ["--version"], { encoding: "utf8", timeout: 10_000 });
  assert.equal(ver.status, 0, ver.stderr);
  assert.equal(ver.stdout.trim(), "stillfail-station-pion 0.1.0 roles:rig commands:");
  assert.equal(ver.stdout.trim().split(/\s+/).length, 4);

  const sys = spawnSync(bin, ["--smoke-sys"], { encoding: "utf8", timeout: 10_000 });
  assert.equal(sys.status, 0, sys.stderr);
  assert.equal(JSON.parse(sys.stdout.trim()).ok, true);

  const http = spawnSync(bin, ["--smoke-http"], { encoding: "utf8", timeout: 15_000 });
  assert.equal(http.status, 0, http.stderr);
  const httpOut = JSON.parse(http.stdout.trim());
  assert.equal(httpOut.ok, true);
  assert.equal(httpOut.http, true);
  assert.equal(httpOut.sse, true);
  assert.equal(httpOut.ws, true);
});

test("Gate 12.2: rig daemon rejects non-rig dir, obeys hub.json handover barrier, serves /healthz, and drains cleanly", { skip: process.platform === "win32" }, async () => {
  // (a) Non-rig data dir is rejected with clear failure on control pipe.
  const wholeDir = freshDir("whole-reject");
  mkdirSync(join(wholeDir, "mesh"), { recursive: true });
  writeFileSync(join(wholeDir, "mesh/cloud.json"), JSON.stringify({ workspace: "ws-whole", station: "aa".repeat(32) }));
  const badRig = startPionRig(bin, wholeDir);
  const badCode = await badRig.waitExit();
  assert.notEqual(badCode, 0, "whole-mode data dir must exit non-zero");
  assert.ok(badRig.messages.some((m) => typeof m.failed === "string" && m.failed.includes("not a rig-only")), `expected failed msg: ${JSON.stringify(badRig.messages)}`);

  // (b) Historical Node DB + rig cloud.json + live previous hub.json PID -> handover barrier -> /healthz -> drain -> stop.
  const data = freshDir("handover-barrier");
  const owner = makeOwner("owner-1");
  const rigSeed = randomBytes(32);
  const rigId = "11".repeat(32);
  const peerId = "22".repeat(32);
  seedRigDataDir(data, owner.genesis(), rigSeed, rigId, peerId);

  // Create historical Node SQLite DB via Node `Store.open`.
  const nodeStore = Store.open(join(data, "stillfail.db"));
  nodeStore.close();

  // Spawn a live dummy previous process and record its PID in `<data>/run/hub.json`.
  const prev = spawn("sleep", ["30"], { stdio: "ignore" });
  children.push(prev);
  assert.ok(prev.pid && prev.pid > 0);
  mkdirSync(join(data, "run"), { recursive: true });
  writeFileSync(join(data, "run/hub.json"), JSON.stringify({ pid: prev.pid }) + "\n");

  const rig = startPionRig(bin, data);

  // Wait for loopback `admin` serving + `ready`, while verifying `mcp` is NOT served yet and `hub.json` still holds prev.pid!
  const adminMsg = await until("serving admin", () => rig.messages.find((m) => m.serving === "admin"));
  const adminPort = Number(adminMsg.port);
  assert.ok(adminPort > 0);
  await until("ready message", () => rig.messages.find((m) => m.ready === true));

  // Verify handover barrier holds while `prev` is alive.
  await new Promise((r) => setTimeout(r, 200));
  assert.equal(JSON.parse(readFileSync(join(data, "run/hub.json"), "utf8")).pid, prev.pid, "hub.json must not be overwritten before previous PID exits");
  assert.equal(rig.messages.some((m) => m.serving === "mcp"), false, "mcp door must wait for previous PID to exit");

  // Kill previous process -> Pion rig immediately takes over!
  prev.kill("SIGKILL");
  await new Promise<void>((r) => prev.once("exit", () => r()));

  const mcpMsg = await until("serving mcp after previous exited", () => rig.messages.find((m) => m.serving === "mcp"));
  assert.ok(Number(mcpMsg.port) > 0);
  assert.equal(JSON.parse(readFileSync(join(data, "run/hub.json"), "utf8")).pid, rig.child.pid, "hub.json updated to Pion rig PID");

  // Verify `/healthz` returns 200.
  const hz = await httpGet(adminPort, "/healthz");
  assert.equal(hz.status, 200);

  // Drain -> writes `<data>/run/drained` and reports `{"drained":"idle"}`.
  rig.sendCtrl({ op: "drain" });
  await until("drained control reply", () => rig.messages.find((m) => m.drained === "idle"));
  assert.equal(readFileSync(join(data, "run/drained"), "utf8").trim(), "idle");

  // Stop -> graceful exit 0 and `hub.json` cleaned up.
  rig.sendCtrl({ op: "stop" });
  const exitCode = await rig.waitExit();
  assert.equal(exitCode, 0, rig.stderr());
  assert.equal(existsSync(join(data, "run/hub.json")), false, "hub.json removed on graceful shutdown");
});

test("Gate 12.3 & 12.4: real iroh grant/revoke + /jobs/notify + Node <-> Pion <-> Node handover lossless", { skip: process.platform === "win32" }, async (t) => {
  const addon = resolveMeshAddon();
  if (!addon) {
    t.skip("mesh native addon not available");
    return;
  }

  const data = freshDir("cross-engine");
  const ws = "ws-e2e-1";
  const owner = makeOwner("owner-1");

  // Bind a real peer iroh endpoint (simulating a workspace station calling the Pion rig).
  const peerSeed = randomBytes(32);
  const peerEp = await addon.bind({
    secretKey: peerSeed,
    alpns: [PEER_BYTES_ALPN],
    relayUrls: [],
    discovery: false,
    dht: false,
    bindAddr: "127.0.0.1:0",
  });
  endpoints.push(peerEp);
  const peerId = peerEp.id();

  // Bind a temporary endpoint just to derive the rig's exact Ed25519 station ID from `rigSeed`.
  const rigSeed = randomBytes(32);
  const probeEp = await addon.bind({
    secretKey: rigSeed,
    alpns: [],
    relayUrls: [],
    discovery: false,
    dht: false,
    bindAddr: "127.0.0.1:0",
  });
  const rigId = probeEp.id();
  await probeEp.close();

  seedRigDataDir(data, owner.genesis(), rigSeed, rigId, peerId, ws);

  // ── Phase A (Node): seed historical `stillfail.db` with an existing job row ──
  const nodeDbPath = join(data, "stillfail.db");
  const nodeStoreA = Store.open(nodeDbPath);
  const histStartedAt = Date.now() - 60_000;
  nodeStoreA.insertJob({
    id: "job_node_hist",
    sessionKey: `remote:${ws}:${peerId}:chat:hist`,
    name: "node-hist",
    command: "echo hist",
    cwd: data,
    port: null,
    token: "tok-hist",
    state: "exited",
    pgid: null,
    exitCode: 0,
    startedAt: histStartedAt,
    endedAt: histStartedAt + 1000,
    restarts: 0,
    log: join(data, "jobs/logs/job_node_hist.log"),
    watch: false,
  });
  nodeStoreA.close();

  // ── Phase B (Pion): start real `stillfail-station-pion` on the same data dir ──
  const rig = startPionRig(bin, data);
  await until("rig mcp serving", () => rig.messages.find((m) => m.serving === "mcp"));
  const rigAddr = await until("rig mesh socket", () => rig.meshAddr());

  // 1. `describe` (UNGATED) succeeds without grant.
  const desc = await peerRpc(peerEp, rigId, rigAddr, ws, { method: "describe" });
  assert.equal(desc.role, "rig");
  assert.equal(desc.runtime, "pion");

  // 2. Ungranted `task.prepare` is refused!
  await assert.rejects(
    () => peerRpc(peerEp, rigId, rigAddr, ws, {
      method: "task.prepare",
      session: "chat:c1",
      key: "k-ungranted",
      spec: { name: "ungranted", command: "echo nope" },
    }),
    /grant|approved|permission|rig/i,
  );

  // 3. Owner signs a real Ed25519 grant for `chat:c1` and installs it via `rig.grant`.
  const nowSec = Math.floor(Date.now() / 1000);
  const timeout: Timeout = { kind: "fixed", seconds: 600 };
  const grantBody: GrantBody = {
    v: 1,
    sub: owner.sub,
    rig: rigId,
    ws,
    request: "req-e2e-1",
    station: peerId,
    session: "chat:c1",
    chat: "CHAT/c1",
    title: "E2E Chat",
    by: "owner@example.com",
    timeout,
    at: nowSec,
    exp: latest(nowSec, timeout),
  };
  const grantRes = await peerRpc(peerEp, rigId, rigAddr, ws, {
    method: "rig.grant",
    signed: owner.says("grant", grantBody),
    chain: owner.chain,
  });
  assert.ok(grantRes.boot && typeof grantRes.rev === "number");

  // 4. Granted `chat:c1` prepares & starts a real remote task that invokes `stillfail-job notify`!
  await peerRpc(peerEp, rigId, rigAddr, ws, {
    method: "task.prepare",
    session: "chat:c1",
    key: "k-notify",
    spec: {
      name: "notify-task",
      command: "stillfail-job notify 'hello from pion rig' && echo task_done_ok",
    },
  });
  const started = await peerRpc(peerEp, rigId, rigAddr, ws, {
    method: "task.start",
    session: "chat:c1",
    key: "k-notify",
  });
  assert.ok(started.job, "task.start returned job id");

  const doneTask = await until("k-notify exited", async () => {
    const t = await peerRpc(peerEp, rigId, rigAddr, ws, { method: "task.get", session: "chat:c1", key: "k-notify" });
    return t.state === "exited" ? t : null;
  });
  assert.equal(doneTask.exitCode, 0);
  const logRes = await peerRpc(peerEp, rigId, rigAddr, ws, { method: "task.log", session: "chat:c1", key: "k-notify", lines: 20 });
  assert.match(logRes.log, /task_done_ok/);

  // 5. Start a long-running task (`sleep 60`), then owner revokes the grant -> task stops immediately & new task refused!
  await peerRpc(peerEp, rigId, rigAddr, ws, {
    method: "task.prepare",
    session: "chat:c1",
    key: "k-sleeper",
    spec: { name: "sleeper", command: "sleep 60" },
  });
  const sleepStarted = await peerRpc(peerEp, rigId, rigAddr, ws, {
    method: "task.start",
    session: "chat:c1",
    key: "k-sleeper",
  });
  assert.ok(sleepStarted.job);

  // Revoke grant via owner-signed `rig.revoke`.
  await peerRpc(peerEp, rigId, rigAddr, ws, {
    method: "rig.revoke",
    signed: owner.says("revoke", { v: 1, sub: owner.sub, rig: rigId, ws, request: "req-e2e-1", at: nowSec + 1 }),
    chain: owner.chain,
  });

  // In-flight sleeper task must be stopped immediately!
  const stoppedTask = await until("k-sleeper stopped after revoke", async () => {
    const t = await peerRpc(peerEp, rigId, rigAddr, ws, { method: "task.get", session: "chat:c1", key: "k-sleeper" });
    return t.state === "stopped" || t.state === "exited" ? t : null;
  });
  assert.equal(stoppedTask.state, "stopped");

  // Subsequent gated call after revocation is immediately refused!
  await assert.rejects(
    () => peerRpc(peerEp, rigId, rigAddr, ws, {
      method: "task.prepare",
      session: "chat:c1",
      key: "k-after-revoke",
      spec: { name: "after", command: "echo nope" },
    }),
    /grant|revoked|approved|rig/i,
  );

  // Drain and stop Pion rig cleanly.
  rig.sendCtrl({ op: "drain" });
  await until("pion drained", () => rig.messages.find((m) => m.drained === "idle"));
  rig.sendCtrl({ op: "stop" });
  assert.equal(await rig.waitExit(), 0, rig.stderr());
  assert.equal(existsSync(join(data, "run/hub.json")), false);

  // ── Phase C (Node): reopen exact same `stillfail.db` & `grants.json` losslessly ──
  const dbCheck = new DatabaseSync(nodeDbPath, { readOnly: true });
  const histRow = dbCheck.prepare("SELECT id, state, exit_code FROM jobs WHERE id = ?").get("job_node_hist") as any;
  assert.equal(histRow?.id, "job_node_hist");
  assert.equal(histRow?.state, "exited");

  const pionJobRow = dbCheck.prepare("SELECT id, state, exit_code, pgid FROM jobs WHERE id = ?").get(String(started.job)) as any;
  assert.equal(pionJobRow?.id, started.job);
  assert.equal(pionJobRow?.state, "exited");
  assert.equal(pionJobRow?.exit_code, 0);

  const notices = dbCheck.prepare("SELECT text FROM job_notices WHERE job_id = ?").all(String(started.job)) as { text: string }[];
  assert.ok(notices.some((n) => n.text.includes("hello from pion rig")), `expected /jobs/notify notice in stillfail.db, got: ${JSON.stringify(notices)}`);

  // Verify 0 orphan processes from the stopped sleeper job!
  const sleeperRow = dbCheck.prepare("SELECT pgid, state FROM jobs WHERE id = ?").get(String(sleepStarted.job)) as any;
  assert.equal(sleeperRow?.state, "stopped");
  if (sleeperRow?.pgid) {
    assert.equal(isAlive(Number(sleeperRow.pgid)), false, `orphan process ${sleeperRow.pgid} still alive after stop`);
  }
  dbCheck.close();

  // Reopen with Node `Store` to prove full schema & WAL compatibility back in Node.
  const nodeStoreC = Store.open(nodeDbPath);
  assert.equal(nodeStoreC.jobsRunning().length, 0);
  nodeStoreC.close();

  // Verify `grants.json` written by Pion is valid JSON containing the revocation.
  const grantsJson = JSON.parse(readFileSync(join(data, "rig/grants.json"), "utf8"));
  assert.ok(grantsJson.revoked && "req-e2e-1" in grantsJson.revoked, "revocation persisted in grants.json for Node");
});
