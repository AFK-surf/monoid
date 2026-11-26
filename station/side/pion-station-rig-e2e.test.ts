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
import { chmodSync, copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { request as httpRequest } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Duplex } from "node:stream";
import { after, test } from "node:test";
import { fileURLToPath, pathToFileURL } from "node:url";
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

  const owner = makeOwner("owner-launcher");
  const rigSeed = randomBytes(32);
  const probeEp = await addon.bind({ secretKey: rigSeed, alpns: [], relayUrls: [], discovery: false, dht: false, bindAddr: "127.0.0.1:0" });
  const rigId = probeEp.id();
  await probeEp.close();
  seedRigDataDir(data, owner.genesis(), rigSeed, rigId, "33".repeat(32), "ws-launcher");
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
      STILLFAIL_MESH_BIND_ADDR: "127.0.0.1:0",
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

  // 1. Wait for initial Node rig to start and serve `/healthz`.
  let nodePid: number;
  try {
    nodePid = await until("Node rig hub.json pid", () => readHubPidNow(), 15_000);
  } catch (e) {
    throw new Error(`${(e as Error).message}\nlauncher logs:\n${logs}`);
  }
  const adminPort = await until("launcher admin port", () => readAdminPort(), 10_000);
  await until("Node /healthz 200", async () => (await httpGet(adminPort, "/healthz")).status === 200, 10_000);

  // 2. Live `Node -> Pion` hot upgrade via `SIGUSR2` (launcher-coordinated, zero manual kill!).
  writeFileSync(join(data, "config.json"), JSON.stringify({ engine: "pion" }) + "\n");
  lc.kill("SIGUSR2");
  const pionPid1 = await until(
    "Node -> Pion handover switched hub.json pid",
    () => {
      const p = readHubPidNow();
      return p && p !== nodePid ? p : null;
    },
    15_000,
  );
  await until("old Node process exited after handover", () => !isAlive(nodePid), 10_000);
  assert.equal((await httpGet(adminPort, "/healthz")).status, 200);

  // 3. Live `Pion -> Pion` hot upgrade via `SIGUSR2` (launcher-coordinated, zero manual kill!).
  lc.kill("SIGUSR2");
  const pionPid2 = await until(
    "Pion -> Pion handover switched hub.json pid",
    () => {
      const p = readHubPidNow();
      return p && p !== pionPid1 ? p : null;
    },
    15_000,
  );
  await until("old Pion process exited after handover", () => !isAlive(pionPid1), 10_000);
  assert.equal((await httpGet(adminPort, "/healthz")).status, 200);

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
  const tellsA = startInboundTellCollector(peerA);

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

  // Finalize 2nd chunk -> `uploads["inputs/in.txt"] === true`!
  const putRes2 = (await peerRpc(peerA, rigId, rigAddr, wsA, {
    method: "file.put",
    session: "chat:c1",
    key: "k-proto",
    path: "inputs/in.txt",
    offset: chunk1.length,
    final: true,
  }, chunk2)).result;
  assert.equal(putRes2.bytes, chunk2.length);
  const taskJsonAfter = JSON.parse(readFileSync(join(data, "remote/incoming", taskIdProto, "task.json"), "utf8"));
  assert.equal(taskJsonAfter.uploads?.["inputs/in.txt"], true);

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
