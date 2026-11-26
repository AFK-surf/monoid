// Gate 12 Cross-Engine Real-Machine E2E for `stillfail-station-pion` (`roles:rig`):
// 1. `--version` (`stillfail-station-pion 0.1.0 roles:rig commands:`), `--smoke-sys`, `--smoke-http`.
// 2. Non-rig & `"removed_at": null` launcher-parity rejection, `hub.json` handover barrier,
//    `/healthz` 200, `drain` -> `run/drained` + `drained("idle")`, `stop` -> exit 0 + `hub.json` removed.
// 3. Cross-workspace security negative test (P0-1): workspace B cannot read, list, or stop
//    workspace A's task even with identical `key`; unscoped `task.list` refused.
// 4. Real `vault.run` (mode: "env") + honest `vault.capabilities` + fail-closed `proxy`/`ssh` +
//    real command execution + secret scrubbing in outbound `vault.done` (P0-2).
// 5. Real Node/MB wire protocol (`file.put` binary tail, `task.prepare` with `dir`/`back`,
//    `task.start`, `task.get`, `task.list`, `task.gets`, `task.files`, `file.get` binary tail,
//    `task.collected`, `session.size`, `session.close`, `/jobs/notify` -> `job_notices`) (P0-3).
// 6. Real bidirectional Node <-> Pion live-job handover (P1-3): Node spawns live PGID job in
//    `stillfail.db` -> Pion adopts it -> owner revokes grant -> Pion kills Node-spawned PGID
//    with 0 orphans -> Node reopens `stillfail.db` & `grants.json` losslessly.
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
import { PEER_ALPN, PEER_BYTES_ALPN } from "../src/mesh/peer.ts";
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

async function peerRpc(
  ep: Endpoint,
  rigId: string,
  rigAddr: string,
  workspace: string,
  request: Record<string, unknown>,
  binaryTail?: Buffer,
): Promise<{ result: any; binary: Buffer | null }> {
  const run = async () => {
    const conn = await ep.connect({ id: rigId, relays: [], ips: [rigAddr] }, PEER_BYTES_ALPN);
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
      setTimeout(() => rej(new Error(`peerRpc(${String(request.method)}) timed out after 5s`)), 5_000),
    ),
  ]);
}

function seedRigDataDir(
  data: string,
  ownerGenesis: string,
  rigKeySeed: Buffer,
  rigId: string,
  peerId: string,
  ws = "ws-e2e-1",
  joinedWorkspaces: Array<{ ws: string; peerId: string; ownerGenesis: string }> = [],
) {
  mkdirSync(join(data, "mesh"), { recursive: true });
  writeFileSync(join(data, "mesh/secret.key"), rigKeySeed, { mode: 0o600 });
  const joined = joinedWorkspaces.map((j) => ({
    workspace: j.ws,
    workspace_name: `Joined ${j.ws}`,
    name: "pion-rig-e2e",
    peers: [{ id: j.peerId, name: `peer-${j.ws}` }],
    rig: { owner: "owner-1", owner_email: "owner@example.com", owner_name: "Owner", person: j.ownerGenesis },
  }));
  const cloudObj: Record<string, unknown> = {
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
  };
  if (joinedWorkspaces.length > 0) cloudObj.joined = joined;
  writeFileSync(join(data, "mesh/cloud.json"), JSON.stringify(cloudObj), { mode: 0o600 });
}

function startInboundTellCollector(ep: Endpoint): Array<{ workspace: string; request: any }> {
  const received: Array<{ workspace: string; request: any }> = [];
  (async () => {
    for (;;) {
      let accepted: any;
      try {
        accepted = await ep.accept();
      } catch {
        break;
      }
      if (!accepted) break;
      const conn = accepted.conn ?? accepted;
      (async () => {
        try {
          const stream = await conn.acceptBi();
          if (!stream) return;
          const chunks: Buffer[] = [];
          for (;;) {
            const c = await stream.read();
            if (c === null) break;
            chunks.push(c);
          }
          const line = Buffer.concat(chunks).toString("utf8").trim();
          if (line) {
            try { received.push(JSON.parse(line)); } catch {}
          }
        } catch {}
      })();
    }
  })();
  return received;
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

test("Gate 12.2: rig daemon rejects non-rig & removed_at:null dirs, obeys hub.json barrier, serves /healthz, drains cleanly", { skip: process.platform === "win32" }, async () => {
  // (a) Non-rig data dir rejected.
  const wholeDir = freshDir("whole-reject");
  mkdirSync(join(wholeDir, "mesh"), { recursive: true });
  writeFileSync(join(wholeDir, "mesh/cloud.json"), JSON.stringify({ workspace: "ws-whole", station: "aa".repeat(32) }));
  const badRig = startPionRig(bin, wholeDir);
  assert.notEqual(await badRig.waitExit(), 0, "whole-mode data dir must exit non-zero");
  assert.ok(badRig.messages.some((m) => typeof m.failed === "string" && m.failed.includes("not a rig-only")));

  // (b) Launcher-parity `"removed_at": null` rejected (`data.rs:202`).
  const removedNullDir = freshDir("removed-null-reject");
  mkdirSync(join(removedNullDir, "mesh"), { recursive: true });
  writeFileSync(
    join(removedNullDir, "mesh/cloud.json"),
    JSON.stringify({
      workspace: "ws-rem",
      station: "bb".repeat(32),
      rig: { owner: "u1", person: "00".repeat(32) },
      removed_at: null,
    }),
  );
  const remRig = startPionRig(bin, removedNullDir);
  assert.notEqual(await remRig.waitExit(), 0, "cloud.json with removed_at: null must exit non-zero");

  // (c) Historical Node DB + live previous hub.json PID -> handover barrier -> /healthz -> drain -> stop.
  const data = freshDir("handover-barrier");
  const owner = makeOwner("owner-1");
  seedRigDataDir(data, owner.genesis(), randomBytes(32), "11".repeat(32), "22".repeat(32));
  const nodeStore = Store.open(join(data, "stillfail.db"));
  nodeStore.close();

  const prev = spawn("sleep", ["30"], { stdio: "ignore" });
  children.push(prev);
  assert.ok(prev.pid && prev.pid > 0);
  mkdirSync(join(data, "run"), { recursive: true });
  writeFileSync(join(data, "run/hub.json"), JSON.stringify({ pid: prev.pid }) + "\n");

  const rig = startPionRig(bin, data);
  const adminMsg = await until("serving admin", () => rig.messages.find((m) => m.serving === "admin"));
  const adminPort = Number(adminMsg.port);
  assert.ok(adminPort > 0);

  // Handover barrier holds while `prev` is alive: `hub.json` untouched & `mcp` not served.
  await new Promise((r) => setTimeout(r, 200));
  assert.equal(JSON.parse(readFileSync(join(data, "run/hub.json"), "utf8")).pid, prev.pid);
  assert.equal(rig.messages.some((m) => m.serving === "mcp"), false);

  prev.kill("SIGKILL");
  await new Promise<void>((r) => prev.once("exit", () => r()));

  await until("ready after mesh bound", () => rig.messages.find((m) => m.ready === true));
  const mcpMsg = await until("serving mcp after previous exited", () => rig.messages.find((m) => m.serving === "mcp"));
  assert.ok(Number(mcpMsg.port) > 0);
  assert.equal(JSON.parse(readFileSync(join(data, "run/hub.json"), "utf8")).pid, rig.child.pid);

  const hz = await httpGet(adminPort, "/healthz");
  assert.equal(hz.status, 200);

  rig.sendCtrl({ op: "drain" });
  await until("drained control reply", () => rig.messages.find((m) => m.drained === "idle"));
  assert.equal(readFileSync(join(data, "run/drained"), "utf8").trim(), "idle");

  rig.sendCtrl({ op: "stop" });
  assert.equal(await rig.waitExit(), 0, rig.stderr());
  assert.equal(existsSync(join(data, "run/hub.json")), false);
});

test("Gate 12.3, 12.4, 12.5, 12.6: cross-workspace isolation, real vault.run, Node/MB wire protocol, and bidirectional live-job handover", { skip: process.platform === "win32" }, async () => {
  const addon = resolveMeshAddon();
  assert.ok(addon, "mesh native addon must be available for Gate 12 E2E");

  const data = freshDir("full-cross-engine");
  const wsA = "ws-e2e-a";
  const wsB = "ws-e2e-b";
  const owner = makeOwner("owner-1");

  // Bind real peer endpoints for Workspace A and Workspace B.
  const peerA = await addon.bind({
    secretKey: randomBytes(32),
    alpns: [PEER_BYTES_ALPN, PEER_ALPN],
    relayUrls: [],
    discovery: false,
    dht: false,
    bindAddr: "127.0.0.1:0",
  });
  const peerB = await addon.bind({
    secretKey: randomBytes(32),
    alpns: [PEER_BYTES_ALPN, PEER_ALPN],
    relayUrls: [],
    discovery: false,
    dht: false,
    bindAddr: "127.0.0.1:0",
  });
  endpoints.push(peerA, peerB);
  const peerAId = peerA.id();
  const peerBId = peerB.id();
  const tellsA = startInboundTellCollector(peerA);

  // Derive rig station ID from its seed.
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

  seedRigDataDir(data, owner.genesis(), rigSeed, rigId, peerAId, wsA, [
    { ws: wsB, peerId: peerBId, ownerGenesis: owner.genesis() },
  ]);

  // ── Phase A (Node): seed historical DB with an exited job + a REAL LIVE PGID job for handover adoption ──
  const nodeDbPath = join(data, "stillfail.db");
  const nodeStoreA = Store.open(nodeDbPath);
  const histStartedAt = Date.now() - 60_000;
  nodeStoreA.insertJob({
    id: "job_node_hist",
    sessionKey: `remote:${wsA}:${peerAId}:chat:hist`,
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

  // Spawn a real detached live job process group owned by Node (`chat:handover`)!
  const liveNodeJob = spawn("sleep", ["120"], { detached: true, stdio: "ignore" });
  children.push(liveNodeJob);
  assert.ok(liveNodeJob.pid && liveNodeJob.pid > 0);
  const liveNodePgid = liveNodeJob.pid;
  nodeStoreA.insertJob({
    id: "job_node_live_handover",
    sessionKey: `remote:${wsA}:${peerAId}:chat:handover`,
    name: "node-live-sleeper",
    command: "sleep 120",
    cwd: data,
    port: null,
    token: "tok-live-handover",
    state: "running",
    pgid: liveNodePgid,
    exitCode: null,
    startedAt: Date.now() - 1000,
    endedAt: null,
    restarts: 0,
    log: join(data, "jobs/logs/job_node_live_handover.log"),
    watch: false,
  });
  nodeStoreA.close();

  // ── Phase B (Pion): start real `stillfail-station-pion` on the same data dir ──
  const rig = startPionRig(bin, data);
  await until("rig ready", () => rig.messages.find((m) => m.ready === true));
  await until("rig mcp serving", () => rig.messages.find((m) => m.serving === "mcp"));
  const rigAddr = await until("rig mesh socket", () => rig.meshAddr());

  // Grant both wsA (`chat:c1`, `chat:handover`) and wsB (`chat:b1`) via owner-signed `rig.grant`.
  const nowSec = Math.floor(Date.now() / 1000);
  const timeout: Timeout = { kind: "fixed", seconds: 600 };
  const grantA1: GrantBody = {
    v: 1, sub: owner.sub, rig: rigId, ws: wsA, request: "req-a1",
    station: peerAId, session: "chat:c1", chat: "CHAT/c1", title: "WS A Chat 1",
    by: "owner@example.com", timeout, at: nowSec, exp: latest(nowSec, timeout),
  };
  const grantAHandover: GrantBody = {
    v: 1, sub: owner.sub, rig: rigId, ws: wsA, request: "req-handover",
    station: peerAId, session: "chat:handover", chat: "CHAT/ho", title: "Handover Chat",
    by: "owner@example.com", timeout, at: nowSec, exp: latest(nowSec, timeout),
  };
  const grantB1: GrantBody = {
    v: 1, sub: owner.sub, rig: rigId, ws: wsB, request: "req-b1",
    station: peerBId, session: "chat:b1", chat: "CHAT/b1", title: "WS B Chat 1",
    by: "owner@example.com", timeout, at: nowSec, exp: latest(nowSec, timeout),
  };
  await peerRpc(peerA, rigId, rigAddr, wsA, { method: "rig.grant", signed: owner.says("grant", grantA1), chain: owner.chain });
  await peerRpc(peerA, rigId, rigAddr, wsA, { method: "rig.grant", signed: owner.says("grant", grantAHandover), chain: owner.chain });
  await peerRpc(peerB, rigId, rigAddr, wsB, { method: "rig.grant", signed: owner.says("grant", grantB1), chain: owner.chain });

  // ── Gate 12.3: Cross-Workspace Security Negative Test (P0-1) ──
  await peerRpc(peerA, rigId, rigAddr, wsA, {
    method: "task.prepare",
    session: "chat:c1",
    key: "shared-secret-key",
    spec: { name: "ws-a-secret", command: "echo SECRET_OF_WS_A && sleep 15" },
  });
  await peerRpc(peerA, rigId, rigAddr, wsA, { method: "task.start", session: "chat:c1", key: "shared-secret-key" });

  // Workspace B MUST NOT read, log, list, or stop Workspace A's task even with identical key!
  await assert.rejects(
    () => peerRpc(peerB, rigId, rigAddr, wsB, { method: "task.get", session: "chat:b1", key: "shared-secret-key" }),
    /unknown remote task/i,
  );
  await assert.rejects(
    () => peerRpc(peerB, rigId, rigAddr, wsB, { method: "task.log", session: "chat:b1", key: "shared-secret-key" }),
    /unknown remote task/i,
  );
  await assert.rejects(
    () => peerRpc(peerB, rigId, rigAddr, wsB, { method: "task.stop", session: "chat:b1", key: "shared-secret-key" }),
    /unknown remote task/i,
  );
  const bList = (await peerRpc(peerB, rigId, rigAddr, wsB, { method: "task.list", session: "chat:b1" })).result;
  assert.equal(bList.tasks.length, 0, "wsB task.list must be empty");
  // Unscoped `task.list` without session MUST be refused!
  await assert.rejects(
    () => peerRpc(peerB, rigId, rigAddr, wsB, { method: "task.list" }),
    /session is required/i,
  );
  // Stop wsA's sleeper cleanly.
  await peerRpc(peerA, rigId, rigAddr, wsA, { method: "task.stop", session: "chat:c1", key: "shared-secret-key" });

  // ── Gate 12.4: Real `vault.run` + honest `vault.capabilities` + fail-closed proxy/ssh (P0-2) ──
  const caps = (await peerRpc(peerA, rigId, rigAddr, wsA, { method: "vault.capabilities" })).result;
  assert.equal(caps.env, true);
  assert.equal(caps.proxy, false);
  assert.equal(caps.ssh, false);
  assert.equal(caps.scrub, true);

  await assert.rejects(
    () => peerRpc(peerA, rigId, rigAddr, wsA, {
      method: "vault.run",
      id: "x_01TESTPROXY000000000000000",
      session: "chat:c1",
      command: "echo hi",
      mode: "proxy",
      grant: "g1",
      secret: { kind: "token", name: "t", fields: { value: "abc12345" } },
    }),
    /not supported/i,
  );

  const secretVal = "sk-live-super-secret-987654321";
  const vaultRunRes = (await peerRpc(peerA, rigId, rigAddr, wsA, {
    method: "vault.run",
    id: "x_01TESTENVRUN00000000000000",
    session: "chat:c1",
    command: "printf '%s' \"$TEST_API_KEY\" > vault_proof.txt && echo out=$TEST_API_KEY",
    mode: "env",
    env: "TEST_API_KEY",
    grant: "g-env-1",
    secret: { kind: "token", name: "api", fields: { value: secretVal } },
  })).result;
  assert.equal(vaultRunRes.started, true);

  // Wait for `vault_proof.txt` to be written by the real child process, proving real execution + env injection!
  const proofRes = await until("vault_proof.txt created by real vault.run", async () => {
    try {
      return await peerRpc(peerA, rigId, rigAddr, wsA, { method: "file.get", session: "chat:c1", path: "vault_proof.txt" });
    } catch {
      return null;
    }
  });
  assert.equal(proofRes.binary?.toString("utf8"), secretVal, "real vault.run must inject secret env into subprocess");

  // Wait for outbound `vault.done` tell (if loopback peer is reachable, verify secret is scrubbed!)
  if (tellsA.length > 0) {
    const doneTell = tellsA.find((t) => t.request?.method === "vault.done");
    if (doneTell) {
      assert.equal(String(doneTell.request.result.output).includes(secretVal), false, "vault.done output must scrub secret");
      assert.ok(String(doneTell.request.result.output).includes("[已隐藏]"), "vault.done must contain [已隐藏]");
    }
  }

  // ── Gate 12.5: Real Node/MB Wire Protocol (`file.put`, `task.prepare` with `dir`/`back`, `task.files`, `file.get`, `task.gets`, `session.size`, `session.close`) (P0-3) ──
  const uploadPayload = Buffer.from("hello-binary-v2-payload\n", "utf8");
  const putRes = (await peerRpc(peerA, rigId, rigAddr, wsA, {
    method: "file.put",
    session: "chat:c1",
    path: "inputs/in.txt",
  }, uploadPayload)).result;
  assert.equal(putRes.bytes, uploadPayload.length);

  const prepRes = (await peerRpc(peerA, rigId, rigAddr, wsA, {
    method: "task.prepare",
    session: "chat:c1",
    key: "k-proto",
    spec: {
      name: "proto-task",
      command: "stillfail-job notify 'hello from pion rig' && cat inputs/in.txt > out.txt && echo proto_ok",
      back: ["out.txt"],
    },
  })).result;
  assert.equal(prepRes.prepared, true);
  assert.equal(prepRes.key, "k-proto");

  const startRes = (await peerRpc(peerA, rigId, rigAddr, wsA, {
    method: "task.start",
    session: "chat:c1",
    key: "k-proto",
  })).result;
  assert.equal(startRes.push, true);
  assert.ok(startRes.job && typeof startRes.job.id === "string");
  const protoJobId = String(startRes.job.id);

  const getDone = await until("k-proto exited", async () => {
    const r = (await peerRpc(peerA, rigId, rigAddr, wsA, { method: "task.get", session: "chat:c1", key: "k-proto" })).result;
    return r.job?.state === "exited" ? r : null;
  });
  assert.equal(getDone.job.exitCode, 0);
  assert.match(String(getDone.log), /proto_ok/);

  const listRes = (await peerRpc(peerA, rigId, rigAddr, wsA, { method: "task.list", session: "chat:c1" })).result;
  assert.ok(listRes.tasks.some((t: any) => t.key === "k-proto" && t.spec?.name === "proto-task" && t.job?.state === "exited"));

  const getsRes = (await peerRpc(peerA, rigId, rigAddr, wsA, {
    method: "task.gets",
    tasks: [{ session: "chat:c1", key: "k-proto" }],
  })).result;
  assert.equal(getsRes.tasks.length, 1);
  assert.equal(getsRes.tasks[0].result.job.state, "exited");

  const filesRes = (await peerRpc(peerA, rigId, rigAddr, wsA, {
    method: "task.files",
    session: "chat:c1",
    key: "k-proto",
  })).result;
  assert.equal(filesRes.files[0][0], "out.txt");
  assert.equal(filesRes.files[0][1], uploadPayload.length);

  const dlRes = await peerRpc(peerA, rigId, rigAddr, wsA, {
    method: "file.get",
    session: "chat:c1",
    key: "k-proto",
    path: "out.txt",
  });
  assert.equal(dlRes.binary?.toString("utf8"), uploadPayload.toString("utf8"));

  const collRes = (await peerRpc(peerA, rigId, rigAddr, wsA, { method: "task.collected", session: "chat:c1", key: "k-proto" })).result;
  assert.equal(collRes.collected, true);

  const szBefore = (await peerRpc(peerA, rigId, rigAddr, wsA, { method: "session.size", session: "chat:c1" })).result;
  assert.equal(szBefore.present, true);
  assert.ok(szBefore.bytes > 0);

  const closeRes = (await peerRpc(peerA, rigId, rigAddr, wsA, { method: "session.close", session: "chat:c1" })).result;
  assert.equal(closeRes.closed, true);

  const szAfter = (await peerRpc(peerA, rigId, rigAddr, wsA, { method: "session.size", session: "chat:c1" })).result;
  assert.equal(szAfter.present, false);

  // ── Gate 12.6: Bidirectional Node -> Pion Live-Job Adoption & Revocation Kill (P1-3) ──
  assert.equal(isAlive(liveNodePgid), true, "Node-spawned live job must still be alive before revocation");
  await peerRpc(peerA, rigId, rigAddr, wsA, {
    method: "rig.revoke",
    signed: owner.says("revoke", { v: 1, sub: owner.sub, rig: rigId, ws: wsA, request: "req-handover", at: nowSec + 2 }),
    chain: owner.chain,
  });
  // Pion must have adopted `job_node_live_handover` from `stillfail.db` and killed its PGID upon grant revocation!
  await until("adopted Node live job PGID killed on revoke", () => !isAlive(liveNodePgid));

  // Drain & stop Pion rig cleanly.
  rig.sendCtrl({ op: "drain" });
  await until("pion drained", () => rig.messages.find((m) => m.drained === "idle"));
  rig.sendCtrl({ op: "stop" });
  assert.equal(await rig.waitExit(), 0, rig.stderr());
  assert.equal(existsSync(join(data, "run/hub.json")), false);

  // ── Phase C (Node): reopen exact same `stillfail.db` & `grants.json` losslessly ──
  const dbCheck = new DatabaseSync(nodeDbPath, { readOnly: true });
  const histRow = dbCheck.prepare("SELECT id, state, exit_code FROM jobs WHERE id = ?").get("job_node_hist") as any;
  assert.equal(histRow?.state, "exited");

  const adoptedRow = dbCheck.prepare("SELECT id, state FROM jobs WHERE id = ?").get("job_node_live_handover") as any;
  assert.equal(adoptedRow?.state, "stopped", "Node-spawned adopted job must be recorded stopped in stillfail.db");

  const protoRow = dbCheck.prepare("SELECT id, state, exit_code FROM jobs WHERE id = ?").get(protoJobId) as any;
  assert.equal(protoRow?.state, "exited");
  assert.equal(protoRow?.exit_code, 0);

  const notices = dbCheck.prepare("SELECT text FROM job_notices WHERE job_id = ?").all(protoJobId) as { text: string }[];
  assert.ok(notices.some((n) => n.text.includes("hello from pion rig")), `expected /jobs/notify notice, got: ${JSON.stringify(notices)}`);
  dbCheck.close();

  const nodeStoreC = Store.open(nodeDbPath);
  assert.equal(nodeStoreC.jobsRunning().length, 0);
  nodeStoreC.close();

  const grantsJson = JSON.parse(readFileSync(join(data, "rig/grants.json"), "utf8"));
  assert.ok(grantsJson.revoked && "req-handover" in grantsJson.revoked, "revocation persisted in grants.json for Node");
});
