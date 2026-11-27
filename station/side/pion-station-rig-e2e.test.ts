// Gate 12 Cross-Engine Real-Machine E2E for `stillfail-station-pion` (`roles:rig`):
// 1. `--version` (`stillfail-station-pion 0.1.0 roles:rig commands:`), `--smoke-sys`, `--smoke-http`.
// 2. Non-rig & `"removed_at": null` launcher-parity rejection, `hub.json` handover barrier,
//    `/healthz` 200, `drain` -> `run/drained` + `drained("idle")`, `stop` -> exit 0 + `hub.json` removed.
// 3. REAL Rust launcher (`STILLFAIL_LAUNCHER`) live `Node -> Pion` and `Pion -> Pion` hot upgrades
//    via `SIGUSR2` (zero manual kills, zero 40s deadlock; proves `ready` emitted before `previous.gone`).
// 4. Cross-workspace security negative test (P0-1): workspace B cannot read, list, or stop
//    workspace A's task even with identical `key`; unscoped `task.list` refused.
// 5. Real `vault.run` (mode: "env") + honest `vault.capabilities` + fail-closed `proxy`/`ssh` +
//    expired grant rejection + real subprocess execution + UNCONDITIONAL scrubbed `vault.done` (P0-2, P1-10).
// 6. Real Node/MB wire protocol (`file.put` binary tail + offset mismatch check, `task.prepare` with
//    safe derived `spec.dir` + conflict rejection + fail-closed `sandbox`, `task.start` with 64-hex
//    `push` ref + UNCONDITIONAL `task.changed` `{ method: "task.changed", ref }` delivery, recursive
//    `task.files`, `file.get` binary tail, `task.gets`, `session.size`, `session.close`, `/jobs/notify`) (P0-2, P0-3, P1-4).
// 7. Real bidirectional Node <-> Pion live-job handover (P1-3, P1-9): Node spawns live PGID job in
//    `stillfail.db` -> Pion adopts with start-time verification -> owner revokes grant -> Pion kills
//    Node-spawned PGID with 0 orphans & sends full `rig.changed` -> Node reopens DB & grants losslessly.
import assert from "node:assert/strict";
import { type ChildProcess, execFileSync, spawn, spawnSync } from "node:child_process";
import { createHash, generateKeyPairSync, randomBytes, sign as nodeSign } from "node:crypto";
import { createSocket as createUdpSocket } from "node:dgram";
import { chmodSync, copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { request as httpRequest } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Duplex } from "node:stream";
import { after, test } from "node:test";
import { fileURLToPath, pathToFileURL } from "node:url";
import { DatabaseSync } from "node:sqlite";
import { zstdCompressSync } from "node:zlib";
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

function resolveLauncherBinary(): string | null {
  if (process.env.STILLFAIL_LAUNCHER && existsSync(process.env.STILLFAIL_LAUNCHER)) {
    return process.env.STILLFAIL_LAUNCHER;
  }
  try {
    const target = process.platform === "darwin" ? "darwin-arm64"
      : process.arch === "arm64" ? "linux-arm64" : "linux-x64";
    const dir = execFileSync(process.execPath, [join(root, "scripts/native.ts"), "path", "launcher", target], {
      cwd: root,
      encoding: "utf8",
    }).trim();
    const candidate = join(dir, process.platform === "win32" ? "stillfail-station.exe" : "stillfail-station");
    if (existsSync(candidate)) return candidate;
  } catch {}
  return null;
}

function resolveReaderBinary(): string | null {
  if (process.env.STILLFAIL_MB_READER && existsSync(process.env.STILLFAIL_MB_READER)) {
    return process.env.STILLFAIL_MB_READER;
  }
  try {
    const target = process.platform === "darwin" ? "darwin-arm64"
      : process.arch === "arm64" ? "linux-arm64" : "linux-x64";
    const dir = execFileSync(process.execPath, [join(root, "scripts/native.ts"), "path", "reader", target], {
      cwd: root,
      encoding: "utf8",
    }).trim();
    const candidate = join(dir, process.platform === "win32" ? "stillfail-reader.exe" : "stillfail-reader");
    if (existsSync(candidate)) return candidate;
  } catch {}
  return null;
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

async function peerRpcSlow(
  ep: Endpoint,
  rigId: string,
  rigAddr: string,
  workspace: string,
  request: Record<string, unknown>,
  binaryTail: Buffer,
  chunkSize: number,
  delayMs: number,
  timeoutMs = 35_000,
): Promise<{ result: any; binary: Buffer | null }> {
  const run = async () => {
    const conn = await ep.connect({ id: rigId, relays: [], ips: [rigAddr] }, PEER_BYTES_ALPN);
    try {
      const stream = await conn.openBi();
      const env: Record<string, unknown> = { workspace, request, bytes: true };
      await stream.write(Buffer.from(JSON.stringify(env) + "\n"));
      for (let off = 0; off < binaryTail.length; off += chunkSize) {
        if (off > 0) await new Promise((r) => setTimeout(r, delayMs));
        await stream.write(binaryTail.subarray(off, Math.min(off + chunkSize, binaryTail.length)));
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
      setTimeout(() => rej(new Error(`peerRpcSlow(${String(request.method)}) timed out after ${timeoutMs}ms`)), timeoutMs),
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
  joinedWorkspaces: Array<{ ws: string; peerId: string; ownerGenesis: string; peerIps?: string[] }> = [],
  peerIps: string[] = [],
) {
  mkdirSync(join(data, "mesh"), { recursive: true });
  writeFileSync(join(data, "mesh/secret.key"), rigKeySeed, { mode: 0o600 });
  const joined = joinedWorkspaces.map((j) => ({
    workspace: j.ws,
    workspace_name: `Joined ${j.ws}`,
    name: "pion-rig-e2e",
    peers: [{ id: j.peerId, name: `peer-${j.ws}`, ...(j.peerIps?.length ? { ips: j.peerIps } : {}) }],
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
    peers: [{ id: peerId, name: "peer-node", ...(peerIps.length ? { ips: peerIps } : {}) }],
    revocations: [],
    rig: { owner: "owner-1", owner_email: "owner@example.com", owner_name: "Owner", person: ownerGenesis },
  };
  if (joinedWorkspaces.length > 0) cloudObj.joined = joined;
  writeFileSync(join(data, "mesh/cloud.json"), JSON.stringify(cloudObj), { mode: 0o600 });
}

function startInboundTellCollector(
  ep: Endpoint,
  replyFor?: (msg: { workspace: string; request: any }) => Record<string, unknown>,
): Array<{ workspace: string; request: any }> {
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
          let replyObj: Record<string, unknown> = { result: { ok: true } };
          if (line) {
            try {
              const parsed = JSON.parse(line);
              received.push(parsed);
              if (replyFor) replyObj = replyFor(parsed);
            } catch {}
          }
          await stream.write(Buffer.from(JSON.stringify(replyObj) + "\n"));
          await stream.finish();
        } catch {}
      })();
    }
  })();
  return received;
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

test("Gate 12.2: rig daemon rejects non-rig & removed_at:null dirs, emits ready before previous exits, obeys hub.json barrier, drains cleanly", { skip: process.platform === "win32" }, async () => {
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

  // (c) Handover protocol: `ready` MUST arrive while previous PID is STILL ALIVE (no launcher deadlock),
  //     while `hub.json` and `mcp` wait until previous exits!
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
  // P0-1 critical invariant: `ready` arrives BEFORE previous PID exits!
  await until("ready while previous still alive", () => rig.messages.find((m) => m.ready === true));

  await new Promise((r) => setTimeout(r, 150));
  assert.equal(JSON.parse(readFileSync(join(data, "run/hub.json"), "utf8")).pid, prev.pid, "hub.json waits for previous PID");
  assert.equal(rig.messages.some((m) => m.serving === "mcp"), false, "mcp waits for previous PID");

  prev.kill("SIGKILL");
  await new Promise<void>((r) => prev.once("exit", () => r()));

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

  // (d) Stale `{ "pid": 1 }` in `hub.json` MUST be taken over in <2s (never deadlock on init PID!).
  const pid1Dir = freshDir("handover-pid1");
  seedRigDataDir(pid1Dir, owner.genesis(), randomBytes(32), "44".repeat(32), "55".repeat(32));
  const pid1Store = Store.open(join(pid1Dir, "stillfail.db"));
  pid1Store.close();
  mkdirSync(join(pid1Dir, "run"), { recursive: true });
  writeFileSync(join(pid1Dir, "run/hub.json"), JSON.stringify({ pid: 1 }) + "\n");
  const t0 = Date.now();
  const rigPid1 = startPionRig(bin, pid1Dir);
  await until("mcp serving immediately with stale pid:1", () => rigPid1.messages.find((m) => m.serving === "mcp"), 3_000);
  assert.ok(Date.now() - t0 < 3_000, "pid:1 handover must take over immediately");
  const hubAfterPid1 = JSON.parse(readFileSync(join(pid1Dir, "run/hub.json"), "utf8"));
  assert.equal(hubAfterPid1.pid, rigPid1.child.pid);
  assert.ok(typeof hubAfterPid1.procStartTimeMs === "number" && hubAfterPid1.procStartTimeMs > 0);
  if (process.platform === "linux") {
    assert.ok(typeof hubAfterPid1.procStartTicks === "number" && hubAfterPid1.procStartTicks >= 0);
    assert.ok(typeof hubAfterPid1.bootId === "string" && hubAfterPid1.bootId.length >= 16);
  }
  rigPid1.sendCtrl({ op: "stop" });
  assert.equal(await rigPid1.waitExit(), 0, rigPid1.stderr());

  // (e) Same-UID live process whose `procStartTimeMs` in `hub.json` differs by 2s (PID reuse) MUST take over immediately (<1.5s)!
  const reuseDir = freshDir("handover-pid-reuse");
  seedRigDataDir(reuseDir, owner.genesis(), randomBytes(32), "66".repeat(32), "77".repeat(32));
  const reuseStore = Store.open(join(reuseDir, "stillfail.db"));
  reuseStore.close();
  const decoy = spawn("sleep", ["30"], { stdio: "ignore" });
  children.push(decoy);
  assert.ok(decoy.pid && decoy.pid > 1);
  mkdirSync(join(reuseDir, "run"), { recursive: true });
  writeFileSync(join(reuseDir, "run/hub.json"), JSON.stringify({ pid: decoy.pid, procStartTimeMs: Date.now() - 2500 }) + "\n");
  const tReuse = Date.now();
  const rigReuse = startPionRig(bin, reuseDir);
  await until("mcp serving immediately on 2.5s procStartTimeMs mismatch", () => rigReuse.messages.find((m) => m.serving === "mcp"), 2_000);
  assert.ok(Date.now() - tReuse < 2_000, "2.5s procStartTimeMs mismatch must take over immediately");
  assert.equal(JSON.parse(readFileSync(join(reuseDir, "run/hub.json"), "utf8")).pid, rigReuse.child.pid);
  rigReuse.sendCtrl({ op: "stop" });
  assert.equal(await rigReuse.waitExit(), 0, rigReuse.stderr());
  decoy.kill("SIGKILL");
});

test("Gate 12.2b: REAL Rust launcher coordinates Node -> Pion and Pion -> Pion hot upgrades via SIGUSR2 with zero deadlock", { skip: process.platform === "win32" }, async () => {
  const launcher = resolveLauncherBinary();
  assert.ok(launcher, "STILLFAIL_LAUNCHER must be available for Gate 12.2b real launcher handover test");
  const readerBin = resolveReaderBinary();
  assert.ok(readerBin, "STILLFAIL_MB_READER must be available for Node rig in Gate 12.2b");
  const addon = resolveMeshAddon();
  assert.ok(addon, "mesh native addon must be available");

  const app = freshDir("launcher-app");
  const data = freshDir("launcher-data");
  mkdirSync(join(app, "station"), { recursive: true });
  copyFileSync(bin, join(app, "station", "stillfail-station-pion"));
  chmodSync(join(app, "station", "stillfail-station-pion"), 0o755);
  copyFileSync(readerBin, join(app, "station", "stillfail-reader"));
  chmodSync(join(app, "station", "stillfail-reader"), 0o755);
  writeFileSync(
    join(app, "station", "main.js"),
    `import ${JSON.stringify(pathToFileURL(join(root, "station/src/main.ts")).href)};\n`,
  );
  writeFileSync(join(app, "BUILD"), "9900\n");

  const owner = makeOwner("owner-1");
  const rigSeed = randomBytes(32);
  const probeEp = await addon.bind({ secretKey: rigSeed, alpns: [], relayUrls: [], discovery: false, dht: false, bindAddr: "127.0.0.1:0" });
  const rigId = probeEp.id();
  await probeEp.close();
  const peerL = await addon.bind({
    secretKey: randomBytes(32),
    alpns: [PEER_BYTES_ALPN, PEER_ALPN],
    relayUrls: [],
    discovery: false,
    dht: false,
    bindAddr: "127.0.0.1:0",
  });
  endpoints.push(peerL);
  const peerLId = peerL.id();
  const peerLSockets = peerL.sockets().filter((s: string) => s.startsWith("127.0.0.1:"));
  const tellsL = startInboundTellCollector(peerL);
  const frontPort = await pickFreeUdpPort();
  const frontAddr = `127.0.0.1:${frontPort}`;
  const wsL = "ws-launcher";
  seedRigDataDir(data, owner.genesis(), rigSeed, rigId, peerLId, wsL, [], peerLSockets);
  writeFileSync(join(data, "config.json"), JSON.stringify({ engine: "node" }) + "\n");

  let logs = "";
  const lc = spawn(launcher, ["run", "--app", app, "--data", data], {
    stdio: ["ignore", "pipe", "pipe"],
    env: {
      ...process.env,
      STILLFAIL_NODE: process.execPath,
      STILLFAIL_MESH_NATIVE: process.env.STILLFAIL_MESH_NATIVE ?? "",
      STILLFAIL_MB_READER: join(app, "station", "stillfail-reader"),
      STILLFAIL_STATION_PION: join(app, "station", "stillfail-station-pion"),
      STILLFAIL_NO_DISCOVERY: "1",
      STILLFAIL_NO_DHT: "1",
      STILLFAIL_MESH_BIND_ADDR: frontAddr,
    },
  });
  children.push(lc);
  lc.stdout?.on("data", (d) => { logs += d.toString("utf8"); });
  lc.stderr?.on("data", (d) => { logs += d.toString("utf8"); });
  const lcExit = new Promise<number | null>((resolve) => lc.once("exit", (code) => resolve(code)));

  const readHubPidNow = () => {
    try {
      const j = JSON.parse(readFileSync(join(data, "run/hub.json"), "utf8"));
      return typeof j.pid === "number" && j.pid > 0 ? j.pid : null;
    } catch {
      return null;
    }
  };
  const readAdminPort = () => {
    try {
      const j = JSON.parse(readFileSync(join(data, "run/ports.json"), "utf8"));
      return typeof j.admin === "number" && j.admin > 0 ? j.admin : null;
    } catch {
      return null;
    }
  };

  const verifyMeshStage = async (stage: string, grantReqId: string, taskKey: string) => {
    const desc = await until(`${stage}: describe via front`, async () => {
      try {
        const r = (await peerRpc(peerL, rigId, frontAddr, wsL, { method: "describe" })).result;
        return r && typeof r.rev === "number" ? r : null;
      } catch {
        return null;
      }
    }, 10_000);
    assert.ok(desc);
    const nowS = Math.floor(Date.now() / 1000);
    const to: Timeout = { kind: "fixed", seconds: 600 };
    const gb: GrantBody = {
      v: 1, sub: owner.sub, rig: rigId, ws: wsL, request: grantReqId,
      station: peerLId, session: "chat:front", chat: "CHAT/front", title: `Front ${stage}`,
      by: "owner@example.com", timeout: to, at: nowS, exp: latest(nowS, to),
    };
    await peerRpc(peerL, rigId, frontAddr, wsL, { method: "rig.grant", signed: owner.says("grant", gb), chain: owner.chain });
    await peerRpc(peerL, rigId, frontAddr, wsL, {
      method: "task.prepare",
      session: "chat:front",
      key: taskKey,
      spec: { name: taskKey, command: `printf '%s' 'front-${stage}-ok' > out_${taskKey}.txt` },
    });
    const refHex = createHash("sha256").update(`ref-${stage}-${taskKey}`).digest("hex");
    await peerRpc(peerL, rigId, frontAddr, wsL, {
      method: "task.start",
      session: "chat:front",
      key: taskKey,
      push: refHex,
    });
    const done = await until(`${stage}: task ${taskKey} exited via front`, async () => {
      const r = (await peerRpc(peerL, rigId, frontAddr, wsL, { method: "task.get", session: "chat:front", key: taskKey })).result;
      return r.job?.state === "exited" ? r : null;
    }, 10_000);
    assert.equal(done.job.exitCode, 0);
    const dl = await peerRpc(peerL, rigId, frontAddr, wsL, {
      method: "file.get",
      session: "chat:front",
      key: taskKey,
      path: `out_${taskKey}.txt`,
      whole: true,
    });
    assert.equal(dl.binary?.toString("utf8"), `front-${stage}-ok`);
    if (stage !== "node") {
      await until(`${stage}: outbound task.changed tell via front`, () =>
        tellsL.find((t) => t.request?.method === "task.changed" && t.request?.ref === refHex),
      8_000);
    }
  };

  // 1. Wait for initial Node rig to start and serve `/healthz` + mesh via front.
  let nodePid: number;
  try {
    nodePid = await until("Node rig hub.json pid", () => readHubPidNow(), 15_000);
  } catch (e) {
    throw new Error(`${(e as Error).message}\nlauncher logs:\n${logs}`);
  }
  const adminPort = await until("launcher admin port", () => readAdminPort(), 10_000);
  await until("Node /healthz 200", async () => (await httpGet(adminPort, "/healthz")).status === 200, 10_000);
  await verifyMeshStage("node", "req-front-node", "k-front-node");

  // Helper: continuous `describe` + `task.list` loop running from BEFORE `SIGUSR2` across handover -> 0 `this rig is stopping` / 0 refused!
  const runAcrossHandover = async (label: string, trigger: () => void, waitSwitched: () => Promise<void>) => {
    let keepGoing = true;
    let okCount = 0;
    const errors: string[] = [];
    const loop = (async () => {
      let idx = 0;
      while (keepGoing) {
        const method = idx % 2 === 0 ? "describe" : "task.list";
        idx++;
        try {
          const r = (await peerRpc(peerL, rigId, frontAddr, wsL, method === "describe" ? { method } : { method, session: "chat:front" })).result;
          if (method === "describe") assert.ok(typeof r?.rev === "number");
          else assert.ok(Array.isArray(r?.tasks));
          okCount++;
        } catch (e) {
          errors.push(`${method}#${idx}: ${(e as Error).message}`);
        }
      }
    })();
    await new Promise((r) => setTimeout(r, 80));
    trigger();
    await waitSwitched();
    await new Promise((r) => setTimeout(r, 150));
    keepGoing = false;
    await loop;
    assert.ok(okCount >= 10, `${label}: expected >=10 successful calls across handover, got ${okCount}`);
    const heldErrors = errors.filter((e) => /this rig is stopping|refused to accept a new connection/i.test(e));
    assert.deepEqual(heldErrors, [], `${label}: zero held/refused errors across handover (all errors: ${JSON.stringify(errors)})`);
  };

  // 2. Live `Node -> Pion` hot upgrade via `SIGUSR2` with continuous RPC traffic across the cutover!
  let pionPid1 = 0;
  await runAcrossHandover(
    "Node -> Pion",
    () => {
      writeFileSync(join(data, "config.json"), JSON.stringify({ engine: "pion" }) + "\n");
      lc.kill("SIGUSR2");
    },
    async () => {
      pionPid1 = await until(
        "Node -> Pion handover switched hub.json pid",
        () => {
          const p = readHubPidNow();
          return p && p !== nodePid ? p : null;
        },
        15_000,
      );
      await until("old Node process exited after handover", () => !isAlive(nodePid), 10_000);
    },
  );
  assert.equal((await httpGet(adminPort, "/healthz")).status, 200);
  // Opus P1 (R7): 0ms zero-disruption handover on `Node -> Pion` via front: 30 serial `task.list` calls immediately succeed (0 refused)!
  for (let i = 0; i < 30; i++) {
    const r = (await peerRpc(peerL, rigId, frontAddr, wsL, { method: "task.list", session: "chat:front" })).result;
    assert.ok(Array.isArray(r?.tasks), `serial task.list #${i} after Node -> Pion handover must succeed`);
  }
  await verifyMeshStage("pion1", "req-front-pion1", "k-front-pion1");

  // 3. Live `Pion -> Pion` hot upgrade via `SIGUSR2` with continuous RPC traffic across the cutover!
  let pionPid2 = 0;
  await runAcrossHandover(
    "Pion -> Pion",
    () => {
      lc.kill("SIGUSR2");
    },
    async () => {
      pionPid2 = await until(
        "Pion -> Pion handover switched hub.json pid",
        () => {
          const p = readHubPidNow();
          return p && p !== pionPid1 ? p : null;
        },
        15_000,
      );
      await until("old Pion process exited after handover", () => !isAlive(pionPid1), 10_000);
    },
  );
  assert.equal((await httpGet(adminPort, "/healthz")).status, 200);
  await verifyMeshStage("pion2", "req-front-pion2", "k-front-pion2");

  // 3b. Concurrency race gate (Opus P1): 2 rounds x 32 concurrent fresh-connection `task.list` calls via REAL MB front -> 0 failures!
  for (let round = 0; round < 2; round++) {
    const batch = await Promise.all(
      Array.from({ length: 32 }, () =>
        peerRpc(peerL, rigId, frontAddr, wsL, { method: "task.list", session: "chat:front" }),
      ),
    );
    assert.equal(batch.length, 32);
    for (const item of batch) {
      assert.ok(Array.isArray(item.result?.tasks));
    }
  }

  // 3c. Streaming large `file.put` via REAL MB front (>327,680 B: 327,681 B and 524,288 B) -> exact byte-for-byte SHA-256 + `task.start`!
  const big1 = randomBytes(327_681);
  const big2 = randomBytes(524_288);
  await peerRpc(peerL, rigId, frontAddr, wsL, {
    method: "task.prepare",
    session: "chat:front",
    key: "k-front-bigput",
    spec: { name: "bigput", command: "sha256sum big1.bin big2.bin" },
  });
  const bp1 = (await peerRpc(peerL, rigId, frontAddr, wsL, {
    method: "file.put",
    session: "chat:front",
    key: "k-front-bigput",
    path: "big1.bin",
    offset: 0,
    size: big1.length,
  }, big1)).result;
  assert.equal(bp1.bytes, big1.length);
  const bp2 = (await peerRpc(peerL, rigId, frontAddr, wsL, {
    method: "file.put",
    session: "chat:front",
    key: "k-front-bigput",
    path: "big2.bin",
    offset: 0,
    size: big2.length,
  }, big2)).result;
  assert.equal(bp2.bytes, big2.length);
  await peerRpc(peerL, rigId, frontAddr, wsL, { method: "task.start", session: "chat:front", key: "k-front-bigput" });
  const bigDone = await until("k-front-bigput exited", async () => {
    const r = (await peerRpc(peerL, rigId, frontAddr, wsL, { method: "task.get", session: "chat:front", key: "k-front-bigput" })).result;
    return r.job?.state === "exited" ? r : null;
  }, 10_000);
  assert.equal(bigDone.job.exitCode, 0);
  assert.ok(String(bigDone.log).includes(createHash("sha256").update(big1).digest("hex")));
  assert.ok(String(bigDone.log).includes(createHash("sha256").update(big2).digest("hex")));

  // 3d. Astra P1-5 & Source P1 (R7): binary zstd `sync.put` > 512 KiB (524,288 B random) via REAL MB front -> pieces: 1, written: 1!
  const randSync = randomBytes(524_288);
  const randSyncHash = createHash("sha1").update(Buffer.concat([Buffer.from(`blob ${randSync.length}\0`), randSync])).digest("hex");
  const randSyncZstd = zstdCompressSync(randSync);
  assert.ok(randSyncZstd.length > 512 * 1024, "random zstd payload must exceed 512 KiB");
  await peerRpc(peerL, rigId, frontAddr, wsL, {
    method: "task.prepare",
    session: "chat:front",
    key: "k-front-syncput",
    spec: { name: "front-syncput", command: "sha256sum big_sync.bin", dir: "/Users/dev/front-sync" },
  });
  const sbFront = (await peerRpc(peerL, rigId, frontAddr, wsL, { method: "sync.begin", session: "chat:front", key: "k-front-syncput" })).result;
  const spFront = (await peerRpc(peerL, rigId, frontAddr, wsL, {
    method: "sync.put",
    session: "chat:front",
    key: "k-front-syncput",
    id: sbFront.id,
    blobs: [[randSyncHash, randSync.length, 0, randSync.length]],
  }, randSyncZstd)).result;
  assert.equal(spFront.pieces, 1);
  const scFront = (await peerRpc(peerL, rigId, frontAddr, wsL, {
    method: "sync.commit",
    session: "chat:front",
    key: "k-front-syncput",
    id: sbFront.id,
    set: [["big_sync.bin", randSyncHash, "100644"]],
    remove: [],
    final: true,
  })).result;
  assert.equal(scFront.synced, true);
  assert.equal(scFront.written, 1);
  await peerRpc(peerL, rigId, frontAddr, wsL, { method: "task.start", session: "chat:front", key: "k-front-syncput" });
  const syncFrontDone = await until("k-front-syncput exited", async () => {
    const r = (await peerRpc(peerL, rigId, frontAddr, wsL, { method: "task.get", session: "chat:front", key: "k-front-syncput" })).result;
    return r.job?.state === "exited" ? r : null;
  }, 10_000);
  assert.equal(syncFrontDone.job.exitCode, 0);
  assert.ok(String(syncFrontDone.log).includes(createHash("sha256").update(randSync).digest("hex")));

  // 3e. Astra P1-4 (R7): slow streaming `file.put` > 16s (589,824 B @ 32 KiB every 950ms = ~16.2s) via REAL MB front must NOT be cut off at 15s!
  const slowBuf = randomBytes(589_824);
  await peerRpc(peerL, rigId, frontAddr, wsL, {
    method: "task.prepare",
    session: "chat:front",
    key: "k-front-slowput",
    spec: { name: "slowput", command: "sha256sum slow.bin" },
  });
  const tSlow0 = Date.now();
  const slowPut = (await peerRpcSlow(peerL, rigId, frontAddr, wsL, {
    method: "file.put",
    session: "chat:front",
    key: "k-front-slowput",
    path: "slow.bin",
    offset: 0,
    size: slowBuf.length,
  }, slowBuf, 32 * 1024, 950)).result;
  assert.ok(Date.now() - tSlow0 >= 15_500, "slow upload must actually span >15.5s");
  assert.equal(slowPut.bytes, slowBuf.length);
  await peerRpc(peerL, rigId, frontAddr, wsL, { method: "task.start", session: "chat:front", key: "k-front-slowput" });
  const slowDone = await until("k-front-slowput exited", async () => {
    const r = (await peerRpc(peerL, rigId, frontAddr, wsL, { method: "task.get", session: "chat:front", key: "k-front-slowput" })).result;
    return r.job?.state === "exited" ? r : null;
  }, 10_000);
  assert.equal(slowDone.job.exitCode, 0);
  assert.ok(String(slowDone.log).includes(createHash("sha256").update(slowBuf).digest("hex")));

  // 4. Clean shutdown via SIGTERM.
  lc.kill("SIGTERM");
  const code = await Promise.race([
    lcExit,
    new Promise<never>((_, rej) => setTimeout(() => rej(new Error(`launcher did not exit cleanly:\n${logs}`)), 15_000)),
  ]);
  assert.equal(code, 0, logs);
  assert.equal(isAlive(pionPid2), false, "child Pion process stopped with launcher");
});

test("Gate 12.3, 12.4, 12.5, 12.6: cross-workspace isolation, real vault.run, Node/MB wire protocol + unconditional task.changed ref, and bidirectional live-job handover", { skip: process.platform === "win32" }, async () => {
  const addon = resolveMeshAddon();
  assert.ok(addon, "mesh native addon must be available for Gate 12 E2E");

  const data = freshDir("full-cross-engine");
  const wsA = "ws-e2e-a";
  const wsB = "ws-e2e-b";
  const owner = makeOwner("owner-1");

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
  const peerASockets = peerA.sockets().filter((s: string) => s.startsWith("127.0.0.1:"));
  assert.ok(peerASockets.length > 0, "peerA loopback socket available");
  const tellsA = startInboundTellCollector(peerA, (msg) => {
    if (msg.request?.method === "vault.used") {
      return { result: { ok: true, until: Math.floor(Date.now() / 1000) + 30 } };
    }
    return { result: { ok: true } };
  });

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

  seedRigDataDir(
    data,
    owner.genesis(),
    rigSeed,
    rigId,
    peerAId,
    wsA,
    [{ ws: wsB, peerId: peerBId, ownerGenesis: owner.genesis() }],
    peerASockets,
  );

  // ── Phase A (Node): seed historical DB with exited job + REAL LIVE PGID job for handover adoption ──
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
    startedAt: Date.now() - 200,
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

  // UNCONDITIONAL assertion: full `rig.changed` payload delivered to `peerA` with `boot`, `rev`, `rig`!
  const rigChangedTell = await until(
    "unconditional rig.changed tell with full payload",
    () => tellsA.find((t) => t.request?.method === "rig.changed" && t.request?.boot && typeof t.request?.rev === "number" && t.request?.rig),
  );
  assert.equal(rigChangedTell.workspace, wsA);

  // ── Gate 12.3: Cross-Workspace Security Negative Test (P0-1) ──
  await peerRpc(peerA, rigId, rigAddr, wsA, {
    method: "task.prepare",
    session: "chat:c1",
    key: "shared-secret-key",
    spec: { name: "ws-a-secret", command: "echo SECRET_OF_WS_A && sleep 15" },
  });
  await peerRpc(peerA, rigId, rigAddr, wsA, { method: "task.start", session: "chat:c1", key: "shared-secret-key" });

  await assert.rejects(
    () => peerRpc(peerB, rigId, rigAddr, wsB, { method: "task.get", session: "chat:b1", key: "shared-secret-key" }),
    /unknown remote task: shared-secret-key/i,
  );
  await assert.rejects(
    () => peerRpc(peerB, rigId, rigAddr, wsB, { method: "task.log", session: "chat:b1", key: "shared-secret-key" }),
    /unknown remote task: shared-secret-key/i,
  );
  await assert.rejects(
    () => peerRpc(peerB, rigId, rigAddr, wsB, { method: "task.stop", session: "chat:b1", key: "shared-secret-key" }),
    /unknown remote task: shared-secret-key/i,
  );
  const bList = (await peerRpc(peerB, rigId, rigAddr, wsB, { method: "task.list", session: "chat:b1" })).result;
  assert.equal(bList.tasks.length, 0);
  await assert.rejects(() => peerRpc(peerB, rigId, rigAddr, wsB, { method: "task.list" }), /session is required/i);
  await peerRpc(peerA, rigId, rigAddr, wsA, { method: "task.stop", session: "chat:c1", key: "shared-secret-key" });

  // ── Gate 12.4: Real `vault.run` + honest `vault.capabilities` + expired grant rejection + UNCONDITIONAL scrubbed `vault.done` (P0-2, P1-10) ──
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
  // Expired grant MUST be refused before spawning!
  await assert.rejects(
    () => peerRpc(peerA, rigId, rigAddr, wsA, {
      method: "vault.run",
      id: "x_01TESTEXPIRED0000000000000",
      session: "chat:c1",
      command: "echo hi",
      mode: "env",
      env: "TEST_API_KEY",
      grant: "g-exp",
      expires: nowSec - 10,
      secret: { kind: "token", name: "t", fields: { value: "abc12345" } },
    }),
    /expired/i,
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
    grantTimeout: { kind: "idle", seconds: 60 },
    secret: { kind: "token", name: "api", fields: { value: secretVal } },
  })).result;
  assert.equal(vaultRunRes.started, true);

  // UNCONDITIONAL assertion: `vault.used` and `vault.done` delivered over iroh with secret scrubbed to `[已隐藏]`!
  await until(
    "unconditional vault.used tell for idle grantTimeout",
    () => tellsA.find((t) => t.request?.method === "vault.used" && t.request?.id === "x_01TESTENVRUN00000000000000"),
    8_000,
  );
  let vaultDoneTell: any;
  try {
    vaultDoneTell = await until(
      "unconditional vault.done tell with scrubbed output",
      () => tellsA.find((t) => t.request?.method === "vault.done" && t.request?.id === "x_01TESTENVRUN00000000000000"),
      8_000,
    );
  } catch (e) {
    throw new Error(`${(e as Error).message}; tellsA=${JSON.stringify(tellsA.map((t) => t.request?.method))}; stderr=\n${rig.stderr()}`);
  }
  assert.equal(vaultDoneTell.request.result.code, 0);
  assert.equal(vaultDoneTell.request.result.used, true);
  assert.equal(String(vaultDoneTell.request.result.output).includes(secretVal), false, "vault.done MUST scrub secret");
  assert.ok(String(vaultDoneTell.request.result.output).includes("[已隐藏]"), "vault.done MUST contain [已隐藏]");

  const proofRes = await peerRpc(peerA, rigId, rigAddr, wsA, { method: "file.get", session: "chat:c1", path: "vault_proof.txt" });
  assert.equal(proofRes.binary?.toString("utf8"), secretVal);

  // Vault `vault.used` renewal: 4s command, 10s command timeout, initial 2s grant expiry, `vault.used` returns `until = now + 30s` -> MUST exit 0!
  const renewRunRes = (await peerRpc(peerA, rigId, rigAddr, wsA, {
    method: "vault.run",
    id: "x_01TESTRENEW000000000000000",
    session: "chat:c1",
    command: "sleep 4 && echo renewed_ok",
    mode: "env",
    env: "TEST_API_KEY",
    grant: "g-renew-1",
    timeoutMs: 10_000,
    expires: Math.floor(Date.now() / 1000) + 2,
    grantTimeout: { kind: "idle", seconds: 20 },
    secret: { kind: "token", name: "api", fields: { value: secretVal } },
  })).result;
  assert.equal(renewRunRes.started, true);
  const renewDone = await until(
    "renewed vault.done after 4s sleep",
    () => tellsA.find((t) => t.request?.method === "vault.done" && t.request?.id === "x_01TESTRENEW000000000000000"),
    10_000,
  );
  assert.equal(renewDone.request.result.code, 0);
  assert.equal(renewDone.request.result.timedOut, false);
  assert.match(String(renewDone.request.result.output), /renewed_ok/);

  // ── Gate 12.5: Node/MB wire protocol + REAL dirsync + 2-chunk `file.put` + 300 KiB `file.get whole:true` + `task.changed` ref ──
  // Fail-closed on explicit sandbox request.
  await assert.rejects(
    () => peerRpc(peerA, rigId, rigAddr, wsA, {
      method: "task.prepare",
      session: "chat:c1",
      key: "k-sandbox",
      sandbox: "l4es-1",
      spec: { name: "sbx", command: "echo hi" },
    }),
    /sandboxes are not supported/i,
  );

  // Safe derived mirror name from `spec.dir` + REAL `sync.begin`/`sync.manifest`/`sync.put`/`sync.commit`!
  const dirPrep = (await peerRpc(peerA, rigId, rigAddr, wsA, {
    method: "task.prepare",
    session: "chat:c1",
    key: "k-dir-sync",
    spec: { name: "dir-task", command: "cat synced/hello.txt", dir: "/Users/dev/my:project" },
  })).result;
  assert.equal(dirPrep.dir, "my_project");
  const sb = (await peerRpc(peerA, rigId, rigAddr, wsA, { method: "sync.begin", session: "chat:c1", key: "k-dir-sync" })).result;
  assert.equal(sb.dir, "my_project");
  assert.ok(typeof sb.id === "string" && sb.id.length > 0);
  const sm = (await peerRpc(peerA, rigId, rigAddr, wsA, { method: "sync.manifest", session: "chat:c1", key: "k-dir-sync", id: sb.id })).result;
  assert.deepEqual(sm.entries, []);
  assert.equal(sm.next, null);
  const syncedBytes = Buffer.from("real-dirsync-content-r4\n", "utf8");
  const blobHash = createHash("sha1").update(Buffer.concat([Buffer.from(`blob ${syncedBytes.length}\0`), syncedBytes])).digest("hex");
  const sp = (await peerRpc(peerA, rigId, rigAddr, wsA, {
    method: "sync.put",
    session: "chat:c1",
    key: "k-dir-sync",
    id: sb.id,
    pieces: [[blobHash, syncedBytes.length, 0, syncedBytes.length]],
  }, syncedBytes)).result;
  assert.equal(sp.pieces, 1);
  const sc = (await peerRpc(peerA, rigId, rigAddr, wsA, {
    method: "sync.commit",
    session: "chat:c1",
    key: "k-dir-sync",
    id: sb.id,
    set: [["synced/hello.txt", blobHash, "100644"]],
    remove: [],
    final: true,
  })).result;
  assert.equal(sc.synced, true);
  assert.equal(sc.written, 1);
  assert.equal(sc.version, 1);
  // Start `k-dir-sync` and confirm it actually reads `synced/hello.txt` from disk!
  await peerRpc(peerA, rigId, rigAddr, wsA, { method: "task.start", session: "chat:c1", key: "k-dir-sync" });
  const dirDone = await until("k-dir-sync exited", async () => {
    const r = (await peerRpc(peerA, rigId, rigAddr, wsA, { method: "task.get", session: "chat:c1", key: "k-dir-sync" })).result;
    return r.job?.state === "exited" ? r : null;
  });
  assert.equal(dirDone.job.exitCode, 0);
  assert.match(String(dirDone.log), /real-dirsync-content-r4/);

  // Incremental dirsync rename WITHOUT re-uploading blob + Base64+zstd `sync.put`!
  const dirPrep2 = (await peerRpc(peerA, rigId, rigAddr, wsA, {
    method: "task.prepare",
    session: "chat:c1",
    key: "k-dir-rename",
    spec: { name: "dir-rename", command: "cat synced/renamed.txt && cat synced/zstd.txt", dir: "/Users/dev/my:project" },
  })).result;
  assert.equal(dirPrep2.dir, "my_project");
  const sb2 = (await peerRpc(peerA, rigId, rigAddr, wsA, { method: "sync.begin", session: "chat:c1", key: "k-dir-rename" })).result;
  const zstdPlain = Buffer.from("zstd-base64-payload-r5\n", "utf8");
  const zstdHash = createHash("sha1").update(Buffer.concat([Buffer.from(`blob ${zstdPlain.length}\0`), zstdPlain])).digest("hex");
  const zstdCompB64 = zstdCompressSync(zstdPlain).toString("base64");
  const sp2 = (await peerRpc(peerA, rigId, rigAddr, wsA, {
    method: "sync.put",
    session: "chat:c1",
    key: "k-dir-rename",
    id: sb2.id,
    blobs: [[zstdHash, zstdPlain.length, 0, zstdPlain.length]],
    data: zstdCompB64,
  })).result;
  assert.equal(sp2.pieces, 1);
  // Commit reuses `blobHash` from existing `synced/hello.txt` without re-uploading it, removes old path, and writes `synced/zstd.txt`!
  const sc2 = (await peerRpc(peerA, rigId, rigAddr, wsA, {
    method: "sync.commit",
    session: "chat:c1",
    key: "k-dir-rename",
    id: sb2.id,
    set: [["synced/renamed.txt", blobHash, "100644"], ["synced/zstd.txt", zstdHash, "100644"]],
    remove: ["synced/hello.txt"],
    final: true,
  })).result;
  assert.equal(sc2.synced, true);
  assert.equal(sc2.written, 2);
  assert.equal(sc2.removed, 1);
  assert.equal(sc2.version, 2);
  await peerRpc(peerA, rigId, rigAddr, wsA, { method: "task.start", session: "chat:c1", key: "k-dir-rename" });
  const dirDone2 = await until("k-dir-rename exited", async () => {
    const r = (await peerRpc(peerA, rigId, rigAddr, wsA, { method: "task.get", session: "chat:c1", key: "k-dir-rename" })).result;
    return r.job?.state === "exited" ? r : null;
  });
  assert.equal(dirDone2.job.exitCode, 0);
  assert.match(String(dirDone2.log), /real-dirsync-content-r4/);
  assert.match(String(dirDone2.log), /zstd-base64-payload-r5/);

  // Verify MB-compatible `files` object manifest format on disk (`{ dir, name, version, files: { path: [id, mode, ...] } }`)!
  const roomIdA = createHash("sha256").update(JSON.stringify([wsA, peerAId, "chat:c1"])).digest("hex");
  const mirrorRootA = join(data, "remote/sessions", roomIdA, "work/my_project");
  const manifestPathA = join(data, "remote/sessions", roomIdA, "mirrors/my_project.json");
  const manifestObj = JSON.parse(readFileSync(manifestPathA, "utf8"));
  assert.equal(manifestObj.name, "my_project");
  assert.equal(manifestObj.version, 2);
  assert.ok(manifestObj.files && typeof manifestObj.files === "object" && !Array.isArray(manifestObj.files));
  assert.equal(manifestObj.files["synced/renamed.txt"]?.[0], blobHash);

  // Astra P1-2: Remote edit after `sync.begin` -> `sync.commit` removing it MUST fail with conflict and preserve edited content!
  await peerRpc(peerA, rigId, rigAddr, wsA, {
    method: "task.prepare",
    session: "chat:c1",
    key: "k-dir-conflict",
    spec: { name: "dir-conflict", command: "true", dir: "/Users/dev/my:project" },
  });
  const sbConf = (await peerRpc(peerA, rigId, rigAddr, wsA, { method: "sync.begin", session: "chat:c1", key: "k-dir-conflict" })).result;
  // Also verify `sync.base` reads back the MB `files` manifest entries!
  const baseRes = (await peerRpc(peerA, rigId, rigAddr, wsA, { method: "sync.base", session: "chat:c1", key: "k-dir-conflict", id: sbConf.id })).result;
  assert.ok(baseRes.entries.some((e: any) => e[0] === "synced/renamed.txt" && e[1] === blobHash));
  writeFileSync(join(mirrorRootA, "synced/renamed.txt"), "remote-edited-after-begin\n");
  await assert.rejects(
    () => peerRpc(peerA, rigId, rigAddr, wsA, {
      method: "sync.commit",
      session: "chat:c1",
      key: "k-dir-conflict",
      id: sbConf.id,
      set: [],
      remove: ["synced/renamed.txt"],
      final: true,
    }),
    /sync conflict at synced\/renamed\.txt: the remote file changed before removal/i,
  );
  assert.equal(readFileSync(join(mirrorRootA, "synced/renamed.txt"), "utf8"), "remote-edited-after-begin\n");
  // Restore `synced/renamed.txt` to original content so next rename test can run cleanly.
  writeFileSync(join(mirrorRootA, "synced/renamed.txt"), syncedBytes);

  // Astra P1-3 (R7): POSIX executable bit preservation (`0755` <-> `100755`) — manifest reports `100755` and unmodified deletion succeeds without false conflict!
  const execBytes = Buffer.from("#!/bin/sh\necho exec-r7\n", "utf8");
  const execHash = createHash("sha1").update(Buffer.concat([Buffer.from(`blob ${execBytes.length}\0`), execBytes])).digest("hex");
  const keepOrig = Buffer.from("original\n", "utf8");
  const keepOrigHash = createHash("sha1").update(Buffer.concat([Buffer.from(`blob ${keepOrig.length}\0`), keepOrig])).digest("hex");
  await peerRpc(peerA, rigId, rigAddr, wsA, {
    method: "task.prepare",
    session: "chat:c1",
    key: "k-dir-exec",
    spec: { name: "dir-exec", command: "true", dir: "/Users/dev/my:project" },
  });
  const sbExec = (await peerRpc(peerA, rigId, rigAddr, wsA, { method: "sync.begin", session: "chat:c1", key: "k-dir-exec" })).result;
  await peerRpc(peerA, rigId, rigAddr, wsA, {
    method: "sync.put",
    session: "chat:c1",
    key: "k-dir-exec",
    id: sbExec.id,
    pieces: [
      [execHash, execBytes.length, 0, execBytes.length],
      [keepOrigHash, keepOrig.length, 0, keepOrig.length],
    ],
  }, Buffer.concat([execBytes, keepOrig]));
  const scExec = (await peerRpc(peerA, rigId, rigAddr, wsA, {
    method: "sync.commit",
    session: "chat:c1",
    key: "k-dir-exec",
    id: sbExec.id,
    set: [["synced/run.sh", execHash, "100755"], ["synced/keep.txt", keepOrigHash, "100644"]],
    remove: [],
    final: true,
  })).result;
  assert.equal(scExec.synced, true);
  assert.equal(statSync(join(mirrorRootA, "synced/run.sh")).mode & 0o111, 0o111, "run.sh must be executable 0755");
  await peerRpc(peerA, rigId, rigAddr, wsA, {
    method: "task.prepare",
    session: "chat:c1",
    key: "k-dir-exec-del",
    spec: { name: "dir-exec-del", command: "true", dir: "/Users/dev/my:project" },
  });
  const sbExecDel = (await peerRpc(peerA, rigId, rigAddr, wsA, { method: "sync.begin", session: "chat:c1", key: "k-dir-exec-del" })).result;
  const manExec = (await peerRpc(peerA, rigId, rigAddr, wsA, { method: "sync.manifest", session: "chat:c1", key: "k-dir-exec-del", id: sbExecDel.id })).result;
  assert.ok(manExec.entries.some((e: any) => e[0] === "synced/run.sh" && e[2] === "100755"), "sync.manifest must report 100755 for 0755 file");
  const scExecDel = (await peerRpc(peerA, rigId, rigAddr, wsA, {
    method: "sync.commit",
    session: "chat:c1",
    key: "k-dir-exec-del",
    id: sbExecDel.id,
    set: [],
    remove: ["synced/run.sh"],
    final: true,
  })).result;
  assert.equal(scExecDel.synced, true);
  assert.equal(scExecDel.removed, 1);
  assert.equal(existsSync(join(mirrorRootA, "synced/run.sh")), false);

  // Astra P1-1 (R7): Read-only parent dir causing removal failure MUST abort commit, keep manifest & `synced: false`, and refuse `task.start`!
  await peerRpc(peerA, rigId, rigAddr, wsA, {
    method: "task.prepare",
    session: "chat:c1",
    key: "k-dir-ro-del",
    spec: { name: "dir-ro-del", command: "true", dir: "/Users/dev/my:project" },
  });
  const sbRoDel = (await peerRpc(peerA, rigId, rigAddr, wsA, { method: "sync.begin", session: "chat:c1", key: "k-dir-ro-del" })).result;
  const manifestBeforeRoDel = readFileSync(manifestPathA, "utf8");
  chmodSync(join(mirrorRootA, "synced"), 0o500);
  try {
    await assert.rejects(
      () => peerRpc(peerA, rigId, rigAddr, wsA, {
        method: "sync.commit",
        session: "chat:c1",
        key: "k-dir-ro-del",
        id: sbRoDel.id,
        set: [],
        remove: ["synced/renamed.txt"],
        final: true,
      }),
      /failed to remove/i,
    );
    assert.equal(readFileSync(manifestPathA, "utf8"), manifestBeforeRoDel, "manifest must remain unchanged on delete failure");
    await assert.rejects(
      () => peerRpc(peerA, rigId, rigAddr, wsA, { method: "task.start", session: "chat:c1", key: "k-dir-ro-del" }),
      /sync|synced/i,
    );
  } finally {
    chmodSync(join(mirrorRootA, "synced"), 0o700);
  }

  // Astra P1-2 + P2 (R7/R8): Mixed plan (rename into new subdir + overwrite existing `synced/keep.txt` original->replacement with mode 0o664)
  // with unwritable `task.json` MUST roll back new file + empty subdir, deleted old file, manifest, AND overwritten `synced/keep.txt === "original\n"` with exact mode `0o664`;
  // then retrying the exact same `sync.commit` after chmod 0o700 MUST succeed with exact `written: 2, removed: 1` (no duplicate plan count)!
  chmodSync(join(mirrorRootA, "synced/keep.txt"), 0o664);
  assert.equal(statSync(join(mirrorRootA, "synced/keep.txt")).mode & 0o777, 0o664);
  const keepRepl = Buffer.from("replacement\n", "utf8");
  const keepReplHash = createHash("sha1").update(Buffer.concat([Buffer.from(`blob ${keepRepl.length}\0`), keepRepl])).digest("hex");
  await peerRpc(peerA, rigId, rigAddr, wsA, {
    method: "task.prepare",
    session: "chat:c1",
    key: "k-dir-ro",
    spec: { name: "dir-ro", command: "true", dir: "/Users/dev/my:project" },
  });
  const sbRo = (await peerRpc(peerA, rigId, rigAddr, wsA, { method: "sync.begin", session: "chat:c1", key: "k-dir-ro" })).result;
  await peerRpc(peerA, rigId, rigAddr, wsA, {
    method: "sync.put",
    session: "chat:c1",
    key: "k-dir-ro",
    id: sbRo.id,
    pieces: [[keepReplHash, keepRepl.length, 0, keepRepl.length]],
  }, keepRepl);
  const tidRo = createHash("sha256").update(JSON.stringify([wsA, peerAId, "chat:c1", "k-dir-ro"])).digest("hex");
  const incDirRo = join(data, "remote/incoming", tidRo);
  const manifestBeforeRo = readFileSync(manifestPathA, "utf8");
  chmodSync(incDirRo, 0o500);
  try {
    await assert.rejects(
      () => peerRpc(peerA, rigId, rigAddr, wsA, {
        method: "sync.commit",
        session: "chat:c1",
        key: "k-dir-ro",
        id: sbRo.id,
        set: [["synced/newsub/moved_fail.txt", blobHash, "100644"], ["synced/keep.txt", keepReplHash, "100644"]],
        remove: ["synced/renamed.txt"],
        final: true,
      }),
      /failed to write task\.json|failed to rename task\.json/i,
    );
    assert.equal(existsSync(join(mirrorRootA, "synced/renamed.txt")), true, "old file MUST be restored when task.json fails");
    assert.equal(readFileSync(join(mirrorRootA, "synced/renamed.txt"), "utf8"), syncedBytes.toString("utf8"));
    assert.equal(existsSync(join(mirrorRootA, "synced/newsub/moved_fail.txt")), false, "uncommitted new file MUST be rolled back");
    assert.equal(existsSync(join(mirrorRootA, "synced/newsub")), false, "empty parent dir created for failed new file MUST be cleaned up");
    assert.equal(readFileSync(join(mirrorRootA, "synced/keep.txt"), "utf8"), "original\n", "overwritten file MUST be restored byte-for-byte");
    assert.equal(statSync(join(mirrorRootA, "synced/keep.txt")).mode & 0o777, 0o664, "rolled back file MUST preserve exact original mode 0o664");
    assert.equal(readFileSync(manifestPathA, "utf8"), manifestBeforeRo, "manifest MUST be restored");
  } finally {
    chmodSync(incDirRo, 0o700);
  }
  const scRetry = (await peerRpc(peerA, rigId, rigAddr, wsA, {
    method: "sync.commit",
    session: "chat:c1",
    key: "k-dir-ro",
    id: sbRo.id,
    set: [["synced/newsub/moved_fail.txt", blobHash, "100644"], ["synced/keep.txt", keepReplHash, "100644"]],
    remove: ["synced/renamed.txt"],
    final: true,
  })).result;
  assert.equal(scRetry.synced, true);
  assert.equal(scRetry.written, 2, "retried sync.commit must not double-count written");
  assert.equal(scRetry.removed, 1, "retried sync.commit must not double-count removed");
  assert.equal(readFileSync(join(mirrorRootA, "synced/keep.txt"), "utf8"), "replacement\n");

  // Astra P1-2 (R8): File-to-directory-child rename (`item` -> `item/nested` and back `item/nested` -> `item`) reusing blob!
  const itemBytes = Buffer.from("file-to-nested-r8\n", "utf8");
  const itemHash = createHash("sha1").update(Buffer.concat([Buffer.from(`blob ${itemBytes.length}\0`), itemBytes])).digest("hex");
  await peerRpc(peerA, rigId, rigAddr, wsA, {
    method: "task.prepare",
    session: "chat:c1",
    key: "k-dir-item1",
    spec: { name: "dir-item1", command: "true", dir: "/Users/dev/my:project" },
  });
  const sbItem1 = (await peerRpc(peerA, rigId, rigAddr, wsA, { method: "sync.begin", session: "chat:c1", key: "k-dir-item1" })).result;
  await peerRpc(peerA, rigId, rigAddr, wsA, {
    method: "sync.put",
    session: "chat:c1",
    key: "k-dir-item1",
    id: sbItem1.id,
    pieces: [[itemHash, itemBytes.length, 0, itemBytes.length]],
  }, itemBytes);
  const scItem1 = (await peerRpc(peerA, rigId, rigAddr, wsA, {
    method: "sync.commit",
    session: "chat:c1",
    key: "k-dir-item1",
    id: sbItem1.id,
    set: [["item", itemHash, "100644"]],
    remove: [],
    final: true,
  })).result;
  assert.equal(scItem1.synced, true);
  await peerRpc(peerA, rigId, rigAddr, wsA, {
    method: "task.prepare",
    session: "chat:c1",
    key: "k-dir-item2",
    spec: { name: "dir-item2", command: "true", dir: "/Users/dev/my:project" },
  });
  const sbItem2 = (await peerRpc(peerA, rigId, rigAddr, wsA, { method: "sync.begin", session: "chat:c1", key: "k-dir-item2" })).result;
  const scItem2 = (await peerRpc(peerA, rigId, rigAddr, wsA, {
    method: "sync.commit",
    session: "chat:c1",
    key: "k-dir-item2",
    id: sbItem2.id,
    set: [["item/nested", itemHash, "100644"]],
    remove: ["item"],
    final: true,
  })).result;
  assert.equal(scItem2.synced, true);
  assert.equal(scItem2.written, 1);
  assert.equal(scItem2.removed, 1);
  assert.equal(readFileSync(join(mirrorRootA, "item/nested"), "utf8"), "file-to-nested-r8\n");
  await peerRpc(peerA, rigId, rigAddr, wsA, {
    method: "task.prepare",
    session: "chat:c1",
    key: "k-dir-item3",
    spec: { name: "dir-item3", command: "true", dir: "/Users/dev/my:project" },
  });
  const sbItem3 = (await peerRpc(peerA, rigId, rigAddr, wsA, { method: "sync.begin", session: "chat:c1", key: "k-dir-item3" })).result;
  const scItem3 = (await peerRpc(peerA, rigId, rigAddr, wsA, {
    method: "sync.commit",
    session: "chat:c1",
    key: "k-dir-item3",
    id: sbItem3.id,
    set: [["item", itemHash, "100644"]],
    remove: ["item/nested"],
    final: true,
  })).result;
  assert.equal(scItem3.synced, true);
  assert.equal(scItem3.written, 1);
  assert.equal(scItem3.removed, 1);
  assert.equal(readFileSync(join(mirrorRootA, "item"), "utf8"), "file-to-nested-r8\n");

  // Astra P1 (R9): Directory rollback fidelity — move `oldslot/file` (`oldslot/` mode 0o750) to `reserved/newdir/renamed`
  // with pre-existing empty `reserved/` dir, force `task.json` failure -> `oldslot/` restored with exact 0o750 mode,
  // `oldslot/file` restored, pre-existing empty `reserved/` preserved, and newly created `reserved/newdir` cleaned up!
  const slotBytes = Buffer.from("oldslot-payload-r9\n", "utf8");
  const slotHash = createHash("sha1").update(Buffer.concat([Buffer.from(`blob ${slotBytes.length}\0`), slotBytes])).digest("hex");
  await peerRpc(peerA, rigId, rigAddr, wsA, {
    method: "task.prepare",
    session: "chat:c1",
    key: "k-dir-slot1",
    spec: { name: "dir-slot1", command: "true", dir: "/Users/dev/my:project" },
  });
  const sbSlot1 = (await peerRpc(peerA, rigId, rigAddr, wsA, { method: "sync.begin", session: "chat:c1", key: "k-dir-slot1" })).result;
  await peerRpc(peerA, rigId, rigAddr, wsA, {
    method: "sync.put",
    session: "chat:c1",
    key: "k-dir-slot1",
    id: sbSlot1.id,
    pieces: [[slotHash, slotBytes.length, 0, slotBytes.length]],
  }, slotBytes);
  const scSlot1 = (await peerRpc(peerA, rigId, rigAddr, wsA, {
    method: "sync.commit",
    session: "chat:c1",
    key: "k-dir-slot1",
    id: sbSlot1.id,
    set: [["oldslot/file", slotHash, "100644"]],
    remove: [],
    final: true,
  })).result;
  assert.equal(scSlot1.synced, true);
  chmodSync(join(mirrorRootA, "oldslot"), 0o750);
  mkdirSync(join(mirrorRootA, "reserved"), { recursive: true });
  assert.equal(statSync(join(mirrorRootA, "oldslot")).mode & 0o777, 0o750);

  await peerRpc(peerA, rigId, rigAddr, wsA, {
    method: "task.prepare",
    session: "chat:c1",
    key: "k-dir-slot2",
    spec: { name: "dir-slot2", command: "true", dir: "/Users/dev/my:project" },
  });
  const sbSlot2 = (await peerRpc(peerA, rigId, rigAddr, wsA, { method: "sync.begin", session: "chat:c1", key: "k-dir-slot2" })).result;
  const tidSlot2 = createHash("sha256").update(JSON.stringify([wsA, peerAId, "chat:c1", "k-dir-slot2"])).digest("hex");
  const incDirSlot2 = join(data, "remote/incoming", tidSlot2);
  chmodSync(incDirSlot2, 0o500);
  try {
    await assert.rejects(
      () => peerRpc(peerA, rigId, rigAddr, wsA, {
        method: "sync.commit",
        session: "chat:c1",
        key: "k-dir-slot2",
        id: sbSlot2.id,
        set: [["reserved/newdir/renamed", slotHash, "100644"]],
        remove: ["oldslot/file"],
        final: true,
      }),
      /failed to write task\.json|failed to rename task\.json/i,
    );
    assert.equal(existsSync(join(mirrorRootA, "oldslot")), true, "oldslot/ MUST be restored on rollback");
    assert.equal(statSync(join(mirrorRootA, "oldslot")).mode & 0o777, 0o750, "oldslot/ MUST preserve exact original mode 0o750");
    assert.equal(readFileSync(join(mirrorRootA, "oldslot/file"), "utf8"), "oldslot-payload-r9\n");
    assert.equal(existsSync(join(mirrorRootA, "reserved")), true, "pre-existing empty reserved/ dir MUST NOT be deleted on rollback");
    assert.equal(existsSync(join(mirrorRootA, "reserved/newdir")), false, "newly created reserved/newdir MUST be cleaned up on rollback");
  } finally {
    chmodSync(incDirSlot2, 0o700);
  }

  // Conflicting re-prepare on same key MUST be rejected!
  await assert.rejects(
    () => peerRpc(peerA, rigId, rigAddr, wsA, {
      method: "task.prepare",
      session: "chat:c1",
      key: "k-dir-sync",
      spec: { name: "dir-task", command: "echo DIFFERENT", dir: "/Users/dev/my:project" },
    }),
    /different inputs/i,
  );

  // Prepare `k-proto` first, verify unstarted `task.get` returns `job: null`, then test 2-chunk `file.put`!
  const prepRes = (await peerRpc(peerA, rigId, rigAddr, wsA, {
    method: "task.prepare",
    session: "chat:c1",
    key: "k-proto",
    spec: {
      name: "proto-task",
      command: "stillfail-job notify 'hello from pion rig' && mkdir -p dist/sub && cat inputs/in.txt > dist/a.txt && echo nested > dist/sub/b.txt && head -c 307200 /dev/zero | tr '\\0' 'Z' > dist/large.bin && echo proto_ok",
      back: ["dist"],
    },
  })).result;
  assert.equal(prepRes.prepared, true);
  const preStartGet = (await peerRpc(peerA, rigId, rigAddr, wsA, { method: "task.get", session: "chat:c1", key: "k-proto" })).result;
  assert.equal(preStartGet.job, null, "unstarted prepared task.get must return job: null");

  const chunk1 = Buffer.from("hello-binary-", "utf8");
  const chunk2 = Buffer.from("v2-payload\n", "utf8");
  const uploadPayload = Buffer.concat([chunk1, chunk2]);
  const putRes1 = (await peerRpc(peerA, rigId, rigAddr, wsA, {
    method: "file.put",
    session: "chat:c1",
    key: "k-proto",
    path: "inputs/in.txt",
    offset: 0,
    final: false,
  }, chunk1)).result;
  assert.equal(putRes1.bytes, chunk1.length);

  // Starting before `final: true` MUST be refused and `task.json` must persist `uploads["inputs/in.txt"] === false`!
  const taskIdProto = createHash("sha256").update(JSON.stringify([wsA, peerAId, "chat:c1", "k-proto"])).digest("hex");
  const taskJsonBefore = JSON.parse(readFileSync(join(data, "remote/incoming", taskIdProto, "task.json"), "utf8"));
  assert.equal(taskJsonBefore.uploads?.["inputs/in.txt"], false);
  await assert.rejects(
    () => peerRpc(peerA, rigId, rigAddr, wsA, { method: "task.start", session: "chat:c1", key: "k-proto" }),
    /incomplete/i,
  );

  // Out-of-order offset MUST be rejected!
  await assert.rejects(
    () => peerRpc(peerA, rigId, rigAddr, wsA, {
      method: "file.put",
      session: "chat:c1",
      key: "k-proto",
      path: "inputs/in.txt",
      offset: 999,
      final: true,
    }, Buffer.from("bad")),
    /offset mismatch/i,
  );

  // Finalize 2nd chunk + same-offset retry + Node whole-file `size` upload (no `final` field) + shorter overwrite!
  const putRes2 = (await peerRpc(peerA, rigId, rigAddr, wsA, {
    method: "file.put",
    session: "chat:c1",
    key: "k-proto",
    path: "inputs/in.txt",
    offset: chunk1.length,
    final: true,
  }, chunk2)).result;
  assert.equal(putRes2.bytes, chunk2.length);
  // Same-offset retry must succeed (`offset <= size`).
  const putRetry = (await peerRpc(peerA, rigId, rigAddr, wsA, {
    method: "file.put",
    session: "chat:c1",
    key: "k-proto",
    path: "inputs/in.txt",
    offset: chunk1.length,
    final: true,
  }, chunk2)).result;
  assert.equal(putRetry.bytes, chunk2.length);
  // Node whole-file upload (`size` without `final`) marks `uploads[path] = true` automatically!
  const wholeBytes = Buffer.from("node-whole-file-r5", "utf8");
  const putWhole = (await peerRpc(peerA, rigId, rigAddr, wsA, {
    method: "file.put",
    session: "chat:c1",
    key: "k-proto",
    path: "inputs/whole.txt",
    offset: 0,
    size: wholeBytes.length,
  }, wholeBytes)).result;
  assert.equal(putWhole.bytes, wholeBytes.length);
  const taskJsonAfter = JSON.parse(readFileSync(join(data, "remote/incoming", taskIdProto, "task.json"), "utf8"));
  assert.equal(taskJsonAfter.uploads?.["inputs/in.txt"], true);
  assert.equal(taskJsonAfter.uploads?.["inputs/whole.txt"], true);

  // Pass 64-hex `push` ref on `task.start` -> UNCONDITIONAL `task.changed` `{ method: "task.changed", ref }`!
  const pushRef = createHash("sha256").update("push-ref-k-proto").digest("hex");
  const startRes = (await peerRpc(peerA, rigId, rigAddr, wsA, {
    method: "task.start",
    session: "chat:c1",
    key: "k-proto",
    push: pushRef,
  })).result;
  assert.equal(startRes.push, true);
  assert.equal(startRes.job.queued, undefined, "running task.start must not also report queued: true");
  const protoJobId = String(startRes.job.id);

  const taskChangedTell = await until(
    "unconditional task.changed tell with exact 64-hex ref",
    () => tellsA.find((t) => t.request?.method === "task.changed" && t.request?.ref === pushRef),
  );
  assert.equal(taskChangedTell.workspace, wsA);
  assert.deepEqual(Object.keys(taskChangedTell.request).sort(), ["method", "ref"]);

  const getDone = await until("k-proto exited", async () => {
    const r = (await peerRpc(peerA, rigId, rigAddr, wsA, { method: "task.get", session: "chat:c1", key: "k-proto" })).result;
    return r.job?.state === "exited" ? r : null;
  });
  assert.equal(getDone.job.exitCode, 0);
  assert.match(String(getDone.log), /proto_ok/);

  // Recursive `task.files` on directory `dist` returns sorted leaf files, NOT `["dist", null]`!
  const filesRes = (await peerRpc(peerA, rigId, rigAddr, wsA, {
    method: "task.files",
    session: "chat:c1",
    key: "k-proto",
    paths: ["dist"],
  })).result;
  assert.deepEqual(
    filesRes.files.map((f: any) => f[0]),
    ["dist/a.txt", "dist/large.bin", "dist/sub/b.txt"],
  );
  assert.equal(filesRes.files[0][1], uploadPayload.length);
  assert.equal(filesRes.files[1][1], 307200);
  assert.ok(filesRes.files[2][1] > 0);

  const dlRes = await peerRpc(peerA, rigId, rigAddr, wsA, {
    method: "file.get",
    session: "chat:c1",
    key: "k-proto",
    path: "dist/a.txt",
  });
  assert.equal(dlRes.binary?.toString("utf8"), uploadPayload.toString("utf8"));

  // Large-file (>262,144 bytes) `file.get` with `whole: true` MUST stream entire 307,200 bytes without truncation!
  const largeDl = await peerRpc(peerA, rigId, rigAddr, wsA, {
    method: "file.get",
    session: "chat:c1",
    key: "k-proto",
    path: "dist/large.bin",
    whole: true,
  });
  assert.equal(largeDl.result.size, 307200);
  assert.equal(largeDl.result.eof, true);
  assert.equal(largeDl.binary?.length, 307200, "whole: true file.get must not truncate at 262,144 bytes");
  assert.equal(
    createHash("sha256").update(largeDl.binary!).digest("hex"),
    createHash("sha256").update(Buffer.alloc(307200, 0x5a)).digest("hex"),
  );

  const collRes = (await peerRpc(peerA, rigId, rigAddr, wsA, { method: "task.collected", session: "chat:c1", key: "k-proto" })).result;
  assert.equal(collRes.collected, true);

  const szBefore = (await peerRpc(peerA, rigId, rigAddr, wsA, { method: "session.size", session: "chat:c1" })).result;
  assert.equal(szBefore.present, true);
  assert.ok(szBefore.bytes > 0);

  const closeRes = (await peerRpc(peerA, rigId, rigAddr, wsA, { method: "session.close", session: "chat:c1" })).result;
  assert.equal(closeRes.closed, true);
  const szAfter = (await peerRpc(peerA, rigId, rigAddr, wsA, { method: "session.size", session: "chat:c1" })).result;
  assert.equal(szAfter.present, false);

  // ── Gate 12.6: Bidirectional Node -> Pion Live-Job Adoption & Revocation Kill (P1-3, P1-9) ──
  assert.equal(isAlive(liveNodePgid), true);
  await peerRpc(peerA, rigId, rigAddr, wsA, {
    method: "rig.revoke",
    signed: owner.says("revoke", { v: 1, sub: owner.sub, rig: rigId, ws: wsA, request: "req-handover", at: nowSec + 2 }),
    chain: owner.chain,
  });
  await until("adopted Node live job PGID killed on revoke", () => !isAlive(liveNodePgid));

  rig.sendCtrl({ op: "drain" });
  await until("pion drained", () => rig.messages.find((m) => m.drained === "idle"));
  rig.sendCtrl({ op: "stop" });
  assert.equal(await rig.waitExit(), 0, rig.stderr());
  assert.equal(existsSync(join(data, "run/hub.json")), false);

  // ── Phase C (Node): reopen exact same `stillfail.db` & `grants.json` losslessly ──
  const dbCheck = new DatabaseSync(nodeDbPath, { readOnly: true });
  const histRow = dbCheck.prepare("SELECT id, state FROM jobs WHERE id = ?").get("job_node_hist") as any;
  assert.equal(histRow?.state, "exited");
  const adoptedRow = dbCheck.prepare("SELECT id, state FROM jobs WHERE id = ?").get("job_node_live_handover") as any;
  assert.equal(adoptedRow?.state, "stopped");
  const protoRow = dbCheck.prepare("SELECT id, state, exit_code FROM jobs WHERE id = ?").get(protoJobId) as any;
  assert.equal(protoRow?.state, "exited");
  assert.equal(protoRow?.exit_code, 0);
  const notices = dbCheck.prepare("SELECT text FROM job_notices WHERE job_id = ?").all(protoJobId) as { text: string }[];
  assert.ok(notices.some((n) => n.text.includes("hello from pion rig")));
  dbCheck.close();

  const nodeStoreC = Store.open(nodeDbPath);
  assert.equal(nodeStoreC.jobsRunning().length, 0);
  nodeStoreC.close();

  const grantsJson = JSON.parse(readFileSync(join(data, "rig/grants.json"), "utf8"));
  assert.ok(grantsJson.revoked && "req-handover" in grantsJson.revoked);
});
