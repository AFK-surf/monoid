// Wave 12-CLI-Main Real-Machine E2E Parity & Launcher Routing Test for `stillfail-station-pion`:
// 1. `--version` exact 4-token handshake (`stillfail-station-pion 0.1.0 roles:rig,whole commands:id,status,lock,channel,enroll,update,heap,admin`).
// 2. Real binary vs real Node `station/src/main.ts` (+ `bin/admin-cli.ts`) parity across all 8 CLI subcommands:
//    `id` (OS CSPRNG keygen + mode 0600), `status`, `lock` (signed genesis Ed25519 verification + reset),
//    `channel`, `enroll` (Ed25519 enroll signature + `--lock`), `update` (signed feed + tamper rejection +
//    `--replace-prepare` `.tar.gz` extraction + verbatim-symlink `copy_dir` + executable mode bits),
//    `heap`, and `admin` (self-signed CA TLS rejection without CA and acceptance with `SSL_CERT_FILE`/`NODE_EXTRA_CA_CERTS`).
// 3. Real Rust launcher (`STILLFAIL_LAUNCHER`) routing the 7 launcher-routed subcommands (+ direct `admin`)
//    under `config.json` `"engine": "pion"` to `stillfail-station-pion` without invoking Node, plus unknown-command strict error vs non-strict Node fallback.
import assert from "node:assert/strict";
import { execFileSync, spawn, spawnSync, type ChildProcess, type SpawnSyncReturns } from "node:child_process";
import { createHash, createPublicKey, generateKeyPairSync, sign as nodeSign, verify as nodeVerify } from "node:crypto";
import { chmodSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, readlinkSync, rmSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import { createServer as createHttpServer, type Server as HttpServer } from "node:http";
import { createServer as createHttpsServer, type Server as HttpsServer } from "node:https";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";
import { fileURLToPath } from "node:url";
import { type Entry, entryHash, signedBytes as entryBytes } from "../../shared/lock.ts";
import { keyId } from "../../shared/release-signed.ts";

const root = fileURLToPath(new URL("../..", import.meta.url));
const nodeMain = join(root, "station/src/main.ts");
const nodeAdminCli = join(root, "bin/admin-cli.ts");

const dirs: string[] = [];
const servers: Array<HttpServer | HttpsServer> = [];
const children: ChildProcess[] = [];

function freshDir(tag: string): string {
  const dir = mkdtempSync(join(tmpdir(), `pion-cli-e2e-${tag}-`));
  dirs.push(dir);
  return dir;
}

after(async () => {
  for (const c of children.splice(0)) {
    if (c.exitCode === null && c.signalCode === null) {
      try { c.kill("SIGKILL"); } catch {}
    }
  }
  for (const s of servers.splice(0)) {
    await new Promise<void>((resolve) => s.close(() => resolve()));
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
  const envLauncher = process.env.STILLFAIL_LAUNCHER;
  if (envLauncher && existsSync(envLauncher)) return envLauncher;
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

function runBin(bin: string, args: string[], env: Record<string, string | undefined> = {}): SpawnSyncReturns<string> {
  return spawnSync(bin, args, {
    cwd: root,
    encoding: "utf8",
    timeout: 20_000,
    env: { ...process.env, ...env },
  });
}

function runNodeCli(args: string[], env: Record<string, string | undefined> = {}): SpawnSyncReturns<string> {
  return spawnSync(process.execPath, [nodeMain, ...args], {
    cwd: root,
    encoding: "utf8",
    timeout: 20_000,
    env: { ...process.env, ...env },
  });
}

interface AsyncRunResult {
  status: number | null;
  stdout: string;
  stderr: string;
}

function runAsync(bin: string, args: string[], env: Record<string, string | undefined> = {}): Promise<AsyncRunResult> {
  return new Promise((resolve, reject) => {
    const child = spawn(bin, args, {
      cwd: root,
      stdio: ["ignore", "pipe", "pipe"],
      env: { ...process.env, ...env },
    });
    children.push(child);
    const out: Buffer[] = [];
    const err: Buffer[] = [];
    child.stdout?.on("data", (c: Buffer) => out.push(c));
    child.stderr?.on("data", (c: Buffer) => err.push(c));
    const timer = setTimeout(() => {
      try { child.kill("SIGKILL"); } catch {}
      reject(new Error(`command timed out: ${bin} ${args.join(" ")}`));
    }, 20_000);
    child.on("error", (e) => {
      clearTimeout(timer);
      reject(e);
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      resolve({
        status: code,
        stdout: Buffer.concat(out).toString("utf8"),
        stderr: Buffer.concat(err).toString("utf8"),
      });
    });
  });
}

function runNodeCliAsync(args: string[], env: Record<string, string | undefined> = {}): Promise<AsyncRunResult> {
  return runAsync(process.execPath, [nodeMain, ...args], env);
}

function runNodeAdminAsync(args: string[], env: Record<string, string | undefined> = {}): Promise<AsyncRunResult> {
  return runAsync(process.execPath, [nodeAdminCli, ...args], env);
}

function edKey() {
  const { privateKey, publicKey } = generateKeyPairSync("ed25519");
  const rawPub = (publicKey.export({ format: "der", type: "spki" }) as Buffer).subarray(-32);
  const hex = rawPub.toString("hex");
  return {
    rawPub,
    b64Pub: rawPub.toString("base64"),
    hex,
    id: `ed25519:${hex}`,
    signHex: (bytes: Uint8Array) => nodeSign(null, bytes, privateKey).toString("hex"),
    signB64: (bytes: Uint8Array) => nodeSign(null, bytes, privateKey).toString("base64"),
  };
}

function platformId(): string {
  const os = process.platform === "darwin" ? "darwin" : process.platform === "win32" ? "win32" : "linux";
  const arch = process.arch === "arm64" ? "arm64" : "x64";
  return `${os}-${arch}`;
}

test("1. --version advertises exact 4-token handshake with all 8 CLI commands", () => {
  const bin = resolvePionBinary();
  const r = runBin(bin, ["--version"]);
  assert.equal(r.status, 0, r.stderr);
  const line = r.stdout.trim();
  assert.equal(line, "stillfail-station-pion 0.1.0 roles:rig,whole commands:id,status,lock,channel,enroll,update,heap,admin");
  assert.equal(line.split(/\s+/).length, 4);
});

test("2. id: OS CSPRNG key generation (mode 0600) and exact Node parity", () => {
  const bin = resolvePionBinary();
  const d1 = freshDir("id-1");
  const d2 = freshDir("id-2");

  const p1 = runBin(bin, ["id", "--data", d1]);
  assert.equal(p1.status, 0, p1.stderr);
  const id1 = p1.stdout.trim();
  assert.match(id1, /^[0-9a-f]{64}$/, `expected 64-hex station id, got: ${id1}`);

  const p2 = runBin(bin, ["id", "--data", d2]);
  assert.equal(p2.status, 0, p2.stderr);
  const id2 = p2.stdout.trim();
  assert.match(id2, /^[0-9a-f]{64}$/);
  assert.notEqual(id1, id2, "two fresh data dirs must generate distinct OS CSPRNG keys");

  const keyFile = join(d1, "mesh", "secret.key");
  const st = statSync(keyFile);
  assert.equal(st.size, 32, "secret.key must be raw 32-byte Ed25519 seed");
  if (process.platform !== "win32") {
    assert.equal(st.mode & 0o777, 0o600, "secret.key must be mode 0600");
  }

  // Node reads the exact same key generated by Pion and outputs the exact same ID.
  const n1 = runNodeCli(["id", "--data", d1]);
  assert.equal(n1.status, 0, n1.stderr);
  assert.equal(n1.stdout.trim(), id1, "Node and Pion must agree on station ID");

  const pJson = runBin(bin, ["id", "--data", d1, "--json"]);
  assert.equal(pJson.status, 0, pJson.stderr);
  assert.deepEqual(JSON.parse(pJson.stdout), { id: id1 });
});

test("3. status & channel: exact Node parity across unenrolled/enrolled states and config updates", () => {
  const bin = resolvePionBinary();
  const data = freshDir("status-channel");
  const app = freshDir("app-channel");
  writeFileSync(join(app, "CHANNEL"), "stable\n");
  writeFileSync(join(data, "config.json"), JSON.stringify({ language: "en" }, null, 2) + "\n");

  // Unenrolled status parity
  const pStatus0 = runBin(bin, ["status", "--data", data]);
  const nStatus0 = runNodeCli(["status", "--data", data]);
  assert.equal(pStatus0.status, 0, pStatus0.stderr);
  assert.equal(nStatus0.status, 0, nStatus0.stderr);
  assert.equal(pStatus0.stdout, nStatus0.stdout, "unenrolled status must match Node");

  // Enrolled state parity
  const k = edKey();
  mkdirSync(join(data, "mesh"), { recursive: true });
  writeFileSync(
    join(data, "mesh", "cloud.json"),
    JSON.stringify({
      origin: "https://app.still.fail",
      workspace: "ws_cli_1",
      workspace_name: "CLI Test WS",
      station: k.hex,
      name: "cli-host",
    }),
  );
  const pStatus1 = runBin(bin, ["status", "--data", data]);
  const nStatus1 = runNodeCli(["status", "--data", data]);
  assert.equal(pStatus1.status, 0, pStatus1.stderr);
  assert.equal(nStatus1.status, 0, nStatus1.stderr);
  assert.equal(pStatus1.stdout, nStatus1.stdout, "enrolled status must match Node");

  const pStatusJson = runBin(bin, ["status", "--data", data, "--json"]);
  assert.equal(pStatusJson.status, 0, pStatusJson.stderr);
  const sj = JSON.parse(pStatusJson.stdout);
  assert.equal(sj.running, false);
  assert.equal(sj.channel, "stable");

  // Channel get/set parity
  const pCh0 = runBin(bin, ["channel", "--app", app, "--data", data]);
  const nCh0 = runNodeCli(["channel", "--app", app, "--data", data]);
  assert.equal(pCh0.status, 0, pCh0.stderr);
  assert.equal(nCh0.status, 0, nCh0.stderr);
  assert.equal(pCh0.stdout, nCh0.stdout);
  assert.equal(pCh0.stdout.trim(), "stable");

  const pChSet = runBin(bin, ["channel", "beta", "--app", app, "--data", data]);
  assert.equal(pChSet.status, 0, pChSet.stderr);
  assert.equal(pChSet.stdout.trim(), "beta");

  const nChRead = runNodeCli(["channel", "--app", app, "--data", data]);
  assert.equal(nChRead.status, 0, nChRead.stderr);
  assert.equal(nChRead.stdout.trim(), "beta");

  const pChJson = runBin(bin, ["channel", "--app", app, "--data", data, "--json"]);
  assert.equal(pChJson.status, 0, pChJson.stderr);
  assert.deepEqual(JSON.parse(pChJson.stdout), { channel: "beta" });

  const pBadCh = runBin(bin, ["channel", "nightly", "--app", app, "--data", data]);
  assert.equal(pBadCh.status, 1, "invalid channel must exit 1");
});

test("4. lock: Ed25519 genesis verification via libcrux and lock status/reset parity with Node", () => {
  const bin = resolvePionBinary();
  const data = freshDir("lock");
  writeFileSync(join(data, "config.json"), JSON.stringify({ language: "en" }) + "\n");
  mkdirSync(join(data, "mesh"), { recursive: true });

  const owner = edKey();
  const stKey = edKey().hex;
  const ws = "ws_lock_1";
  const unsigned = {
    v: 1,
    ws,
    seq: 0,
    prev: null,
    at: 1700000000,
    kind: "genesis",
    body: {
      cloud_keys: { keys: [] },
      devices: [
        { id: owner.hex, kind: "app", label: "owner-laptop", sign_key: owner.id, sub: "u_owner_1" },
      ],
      gateways: [],
      members: [
        { email: "owner@example.test", role: "owner", sub: "u_owner_1" },
      ],
      origins: ["https://app.still.fail"],
      owner: "u_owner_1",
      rp_id: "app.still.fail",
      stations: [{ key: stKey, name: "st-1" }],
    },
  } as Omit<Entry, "sig">;
  const hash = entryHash(unsigned as Entry);
  const signed: Entry = {
    ...unsigned,
    sig: { key: owner.id, alg: "Ed25519", sig: owner.signHex(entryBytes(hash)) },
  } as Entry;

  writeFileSync(
    join(data, "mesh", "cloud.json"),
    JSON.stringify({ origin: "https://app.still.fail", workspace: ws, workspace_name: "Lock WS", station: stKey, name: "st-1" }),
  );
  writeFileSync(join(data, "mesh", "lock.json"), JSON.stringify({ entries: [signed] }, null, 2) + "\n");

  const pStat = runBin(bin, ["lock", "status", "--data", data]);
  const nStat = runNodeCli(["lock", "status", "--data", data]);
  assert.equal(pStat.status, 0, pStat.stderr);
  assert.equal(nStat.status, 0, nStat.stderr);
  assert.equal(pStat.stdout, nStat.stdout, "pinned lock status must match Node");

  const pStatJson = runBin(bin, ["lock", "status", "--data", data, "--json"]);
  assert.equal(pStatJson.status, 0, pStatJson.stderr);
  const lj = JSON.parse(pStatJson.stdout);
  assert.equal(lj.state, "pinned");
  assert.equal(lj.seq, 0);
  assert.equal(lj.head, hash);

  const pReset = runBin(bin, ["lock", "reset", "--data", data]);
  assert.equal(pReset.status, 0, pReset.stderr);
  assert.equal(existsSync(join(data, "mesh", "lock.json")), false, "lock.json must be moved aside on reset");

  const pAfter = runBin(bin, ["lock", "status", "--data", data]);
  const nAfter = runNodeCli(["lock", "status", "--data", data]);
  assert.equal(pAfter.status, 0, pAfter.stderr);
  assert.equal(nAfter.status, 0, nAfter.stderr);
  assert.equal(pAfter.stdout, nAfter.stdout, "post-reset lock status must match Node");
});

test("5. enroll: real HTTP enroll with verified Ed25519 signatures and Node parity", async () => {
  const bin = resolvePionBinary();
  const seen: Array<{ token: string; station: string; signature: string }> = [];

  const srv = createHttpServer((req, res) => {
    if (req.method === "POST" && req.url === "/v1/stations/enroll") {
      const chunks: Buffer[] = [];
      req.on("data", (c: Buffer) => chunks.push(c));
      req.on("end", () => {
        const body = JSON.parse(Buffer.concat(chunks).toString("utf8")) as {
          token: string;
          station: string;
          signature: string;
        };
        seen.push(body);
        const pub = createPublicKey({
          key: {
            kty: "OKP",
            crv: "Ed25519",
            x: Buffer.from(body.station, "hex").toString("base64url"),
          },
          format: "jwk",
        });
        const origin = `http://127.0.0.1:${(srv.address() as { port: number }).port}`;
        const msg = Buffer.from(`stillfail-station-enroll-v1:${origin}:${body.token}:${body.station}`, "utf8");
        const ok = nodeVerify(null, msg, pub, Buffer.from(body.signature, "hex"));
        if (!ok) {
          res.writeHead(401, { "content-type": "application/json" });
          res.end(JSON.stringify({ error: "invalid_signature" }));
          return;
        }
        res.writeHead(200, { "content-type": "application/json" });
        res.end(
          JSON.stringify({
            workspace: "ws_enr_1",
            workspace_name: "Enroll WS",
            station: body.station,
            name: "enrolled-box",
          }),
        );
      });
      return;
    }
    res.writeHead(404);
    res.end();
  });
  servers.push(srv);
  await new Promise<void>((resolve) => srv.listen(0, "127.0.0.1", () => resolve()));
  const origin = `http://127.0.0.1:${(srv.address() as { port: number }).port}`;

  const dPion = freshDir("enroll-pion");
  const dNode = freshDir("enroll-node");
  writeFileSync(join(dPion, "config.json"), JSON.stringify({ language: "en" }) + "\n");
  writeFileSync(join(dNode, "config.json"), JSON.stringify({ language: "en" }) + "\n");
  const lockHash = "a".repeat(64);

  const pRes = await runAsync(bin, ["enroll", origin, "tok_pion_123", "--lock", lockHash, "--data", dPion]);
  assert.equal(pRes.status, 0, `pion enroll failed: ${pRes.stderr}`);
  const nRes = await runNodeCliAsync(["enroll", origin, "tok_node_123", "--lock", lockHash, "--data", dNode]);
  assert.equal(nRes.status, 0, `node enroll failed: ${nRes.stderr}`);

  assert.equal(seen.length, 2, "server must receive valid signed enroll requests from both Pion and Node");
  const pCloud = JSON.parse(readFileSync(join(dPion, "mesh", "cloud.json"), "utf8"));
  const nCloud = JSON.parse(readFileSync(join(dNode, "mesh", "cloud.json"), "utf8"));
  assert.equal(pCloud.workspace, nCloud.workspace);
  assert.equal(pCloud.origin, nCloud.origin);
  assert.equal(pCloud.name, nCloud.name);
  assert.ok(existsSync(join(dPion, "mesh", "lock-pending.json")), "pion enroll --lock must write lock-pending.json");
  assert.ok(existsSync(join(dNode, "mesh", "lock-pending.json")), "node enroll --lock must write lock-pending.json");
  if (process.platform !== "win32") {
    assert.equal(statSync(join(dPion, "mesh", "cloud.json")).mode & 0o777, 0o600, "cloud.json must be mode 0600");
    assert.equal(statSync(join(dPion, "mesh", "lock-pending.json")).mode & 0o777, 0o600, "lock-pending.json must be mode 0600");
    assert.equal(statSync(join(dPion, "mesh", "secret.key")).mode & 0o777, 0o600, "secret.key must be mode 0600");
  }
});

test("6. update: signed release verification, tamper rejection, and --replace-prepare verbatim-symlink .tar.gz", async () => {
  const bin = resolvePionBinary();
  const relKey = edKey();
  const plat = platformId();
  const fakeArchiveSha = createHash("sha256").update("fake-release-archive").digest("hex");
  const fakeNodeSha = createHash("sha256").update("fake-node-bin").digest("hex");

  const releaseObj = {
    kind: "stillfail-station-release",
    version: "0.1.9999",
    build: 9999,
    commit: "deadbeef1234",
    node: "24.22.1",
    builds: {
      [plat]: {
        sha256: fakeArchiveSha,
        size: 1024,
        nodeSha256: fakeNodeSha,
      },
    },
  };
  const releaseBytes = Buffer.from(JSON.stringify(releaseObj), "utf8");
  const validFeed = {
    version: "0.1.9999",
    key: keyId(relKey.b64Pub),
    release: releaseBytes.toString("base64"),
    signature: relKey.signB64(releaseBytes),
  };
  let serveTampered = false;

  const srv = createHttpServer((req, res) => {
    if (req.url === "/releases/station-beta.json") {
      const payload = serveTampered
        ? { ...validFeed, signature: Buffer.alloc(64, 0x42).toString("base64") }
        : validFeed;
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify(payload));
      return;
    }
    res.writeHead(404);
    res.end();
  });
  servers.push(srv);
  await new Promise<void>((resolve) => srv.listen(0, "127.0.0.1", () => resolve()));
  const origin = `http://127.0.0.1:${(srv.address() as { port: number }).port}`;

  const data = freshDir("update-data");
  const app = freshDir("update-app");
  writeFileSync(join(data, "config.json"), JSON.stringify({ language: "en", updateChannel: "beta" }) + "\n");
  mkdirSync(join(data, "mesh"), { recursive: true });
  writeFileSync(
    join(data, "mesh", "cloud.json"),
    JSON.stringify({ origin, workspace: "ws_u1", workspace_name: "Up WS", station: edKey().hex, name: "up-host" }),
  );
  mkdirSync(join(app, "bin"), { recursive: true });
  mkdirSync(join(app, "station"), { recursive: true });
  writeFileSync(join(app, "VERSION"), "0.1.100\n");
  writeFileSync(join(app, "CHANNEL"), "beta\n");
  writeFileSync(join(app, "bin", "install.en.sh"), "#!/bin/sh\necho ok\n");
  writeFileSync(join(app, "bin", "stillfail"), "#!/bin/sh\necho ok\n");
  writeFileSync(join(app, "station", "main.js"), "// main\n");

  const env = { STILLFAIL_RELEASE_KEYS: relKey.b64Pub };

  // Valid signed feed parity
  const pUp = await runAsync(bin, ["update", "--app", app, "--data", data], env);
  const nUp = await runNodeCliAsync(["update", "--app", app, "--data", data], env);
  assert.equal(pUp.status, 0, `pion update failed: ${pUp.stderr}`);
  assert.equal(nUp.status, 0, `node update failed: ${nUp.stderr}`);
  assert.equal(pUp.stdout, nUp.stdout, "verified update plan output must match Node byte-for-byte");
  assert.match(pUp.stdout, /STILLFAIL_CHANNEL=beta/);
  assert.match(pUp.stdout, new RegExp(`STILLFAIL_RELEASE_SHA256=${fakeArchiveSha}`));
  assert.match(pUp.stdout, new RegExp(`STILLFAIL_NODE_SHA256=${fakeNodeSha}`));

  // Tampered signature rejection parity
  serveTampered = true;
  const pTamper = await runAsync(bin, ["update", "--app", app, "--data", data], env);
  const nTamper = await runNodeCliAsync(["update", "--app", app, "--data", data], env);
  assert.equal(pTamper.status, 1, "pion update must reject tampered release signature");
  assert.equal(nTamper.status, 1, "node update must reject tampered release signature");

  // --replace-prepare with real .tar.gz containing a verbatim symlink and executable mode bit
  const srcRoot = freshDir("replace-src");
  const bundleDir = join(srcRoot, "stillfail");
  mkdirSync(join(bundleDir, "bin"), { recursive: true });
  mkdirSync(join(bundleDir, "station"), { recursive: true });
  writeFileSync(join(bundleDir, "bin", "stillfail"), "#!/bin/sh\necho replaced\n");
  chmodSync(join(bundleDir, "bin", "stillfail"), 0o755);
  symlinkSync("./stillfail", join(bundleDir, "bin", "stillfail-link"));
  writeFileSync(join(bundleDir, "station", "main.js"), "// replaced\n");
  const tarball = join(srcRoot, "bundle.tar.gz");
  execFileSync("tar", ["-czf", tarball, "-C", srcRoot, "stillfail"]);

  const stage = join(freshDir("replace-stage"), "stage");
  const pPrep = runBin(bin, [
    "update",
    "--replace-prepare",
    "--app",
    app,
    "--data",
    data,
    "--stage",
    stage,
    "--source",
    tarball,
    "--note",
    "w12-test",
  ]);
  assert.equal(pPrep.status, 0, `pion --replace-prepare failed: ${pPrep.stderr}`);
  assert.match(pPrep.stdout, /kind=bundle/);
  const linkPath = join(stage, "bin", "stillfail-link");
  assert.equal(lstatSync(linkPath).isSymbolicLink(), true, "copy_dir must preserve symlinks without dereferencing");
  assert.equal(readlinkSync(linkPath), "./stillfail", "copy_dir must preserve verbatim symlink target");
  if (process.platform !== "win32") {
    assert.equal(statSync(join(stage, "bin", "stillfail")).mode & 0o111, 0o111, "copy_dir must preserve executable bits");
  }
  assert.ok(existsSync(join(stage, "OVERRIDE")), "--replace-prepare must write OVERRIDE metadata");
});

test("7. heap: real request/answer handshake parity with Node", async () => {
  const bin = resolvePionBinary();
  const data = freshDir("heap");
  const runDir = join(data, "run");
  mkdirSync(runDir, { recursive: true });
  const reqPath = join(runDir, "heap.request");
  const ansPath = join(runDir, "heap.answer");
  const snapPath = join(runDir, "heap-2026-11-27.pion-heap.json");

  // Helper that watches for heap.request and responds with heap.answer.
  const spawnResponder = () => {
    const child = spawn(
      process.execPath,
      [
        "-e",
        `const fs = require('node:fs');
const req = ${JSON.stringify(reqPath)};
const ans = ${JSON.stringify(ansPath)};
const snap = ${JSON.stringify(snapPath)};
const end = Date.now() + 10000;
const tick = () => {
  if (fs.existsSync(req)) {
    fs.rmSync(req, { force: true });
    const tmp = ans + '.' + process.pid + '.tmp';
    fs.writeFileSync(tmp, JSON.stringify({ path: snap, bytes: 2097152, ms: 42 }));
    fs.renameSync(tmp, ans);
    process.exit(0);
  }
  if (Date.now() > end) process.exit(1);
  setTimeout(tick, 20);
};
tick();`,
      ],
      { stdio: "ignore" },
    );
    children.push(child);
    return child;
  };

  spawnResponder();
  const pHeap = runBin(bin, ["heap", "--data", data]);
  assert.equal(pHeap.status, 0, `pion heap failed: ${pHeap.stderr}`);

  spawnResponder();
  const nHeap = runNodeCli(["heap", "--data", data]);
  assert.equal(nHeap.status, 0, `node heap failed: ${nHeap.stderr}`);

  assert.equal(pHeap.stdout, nHeap.stdout, "heap output must match Node");
  assert.equal(pHeap.stdout.trim(), `${snapPath} (2 MB, 42 ms)`);

  spawnResponder();
  const pHeapJson = runBin(bin, ["heap", "--data", data, "--json"]);
  assert.equal(pHeapJson.status, 0, `pion heap --json failed: ${pHeapJson.stderr}`);
  assert.deepEqual(JSON.parse(pHeapJson.stdout), { path: snapPath, bytes: 2097152, ms: 42 });
});

test("8. admin: real self-signed CA TLS rejection without CA and acceptance with SSL_CERT_FILE/NODE_EXTRA_CA_CERTS", async () => {
  const bin = resolvePionBinary();
  const tlsDir = freshDir("admin-tls");
  const caKeyPath = join(tlsDir, "ca.key");
  const caCertPath = join(tlsDir, "ca.pem");
  const keyPath = join(tlsDir, "server.key");
  const csrPath = join(tlsDir, "server.csr");
  const certPath = join(tlsDir, "server.pem");
  const extPath = join(tlsDir, "server.ext");
  execFileSync("openssl", [
    "req",
    "-x509",
    "-newkey",
    "rsa:2048",
    "-nodes",
    "-keyout",
    caKeyPath,
    "-out",
    caCertPath,
    "-days",
    "1",
    "-subj",
    "/CN=Test Local CA",
    "-addext",
    "basicConstraints=critical,CA:TRUE",
    "-addext",
    "keyUsage=critical,keyCertSign,cRLSign",
  ]);
  execFileSync("openssl", [
    "req",
    "-newkey",
    "rsa:2048",
    "-nodes",
    "-keyout",
    keyPath,
    "-out",
    csrPath,
    "-subj",
    "/CN=127.0.0.1",
  ]);
  writeFileSync(
    extPath,
    "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=IP:127.0.0.1\n",
  );
  execFileSync("openssl", [
    "x509",
    "-req",
    "-in",
    csrPath,
    "-CA",
    caCertPath,
    "-CAkey",
    caKeyPath,
    "-CAcreateserial",
    "-out",
    certPath,
    "-days",
    "1",
    "-extfile",
    extPath,
  ]);

  const srv = createHttpsServer(
    { key: readFileSync(keyPath), cert: readFileSync(certPath) },
    (req, res) => {
      if (req.headers.authorization !== "Bearer sfa_test_secret_key") {
        res.writeHead(401, { "content-type": "application/json" });
        res.end(JSON.stringify({ error: "unauthorized" }));
        return;
      }
      if (req.url === "/v1/admin/me") {
        res.writeHead(200, { "content-type": "application/json" });
        res.end(
          JSON.stringify({
            email: "admin@example.test",
            key: {
              id: "ak_123",
              name: "cli-test-key",
              prefix: "sfa_test",
              created_at: 1700000000,
              last_used_at: 1700003600,
              expires_at: null,
            },
          }),
        );
        return;
      }
      res.writeHead(404, { "content-type": "application/json" });
      res.end(JSON.stringify({ error: "not_found" }));
    },
  );
  servers.push(srv);
  await new Promise<void>((resolve) => srv.listen(0, "127.0.0.1", () => resolve()));
  const origin = `https://127.0.0.1:${(srv.address() as { port: number }).port}`;

  // Without CA: MUST fail TLS verification.
  const pNoCa = await runAsync(bin, ["admin", "whoami", "--origin", origin, "--key", "sfa_test_secret_key"], {
    SSL_CERT_FILE: "",
    NODE_EXTRA_CA_CERTS: "",
    HTTPS_PROXY: "",
    https_proxy: "",
  });
  assert.notEqual(pNoCa.status, 0, "admin against self-signed TLS without CA must fail");

  // With SSL_CERT_FILE: MUST succeed and match Node bin/admin-cli.ts.
  const pWithCa = await runAsync(bin, ["admin", "whoami", "--origin", origin, "--key", "sfa_test_secret_key"], {
    SSL_CERT_FILE: caCertPath,
    NODE_EXTRA_CA_CERTS: "",
    HTTPS_PROXY: "",
    https_proxy: "",
  });
  assert.equal(pWithCa.status, 0, `pion admin with SSL_CERT_FILE failed: ${pWithCa.stderr}`);

  const nWithCa = await runNodeAdminAsync(["whoami", "--origin", origin, "--key", "sfa_test_secret_key"], {
    SSL_CERT_FILE: caCertPath,
    NODE_EXTRA_CA_CERTS: caCertPath,
    HTTPS_PROXY: "",
    https_proxy: "",
  });
  assert.equal(nWithCa.status, 0, `node admin-cli failed: ${nWithCa.stderr}`);
  assert.equal(pWithCa.stdout, nWithCa.stdout, "admin whoami output must match bin/admin-cli.ts");
  assert.equal(pWithCa.stdout.trim(), "admin@example.test (key: cli-test-key sfa_test…)");

  // With NODE_EXTRA_CA_CERTS + --json: MUST succeed.
  const pJson = await runAsync(bin, ["admin", "whoami", "--origin", origin, "--key", "sfa_test_secret_key", "--json"], {
    SSL_CERT_FILE: "",
    NODE_EXTRA_CA_CERTS: caCertPath,
    HTTPS_PROXY: "",
    https_proxy: "",
  });
  assert.equal(pJson.status, 0, `pion admin --json with NODE_EXTRA_CA_CERTS failed: ${pJson.stderr}`);
  assert.equal(JSON.parse(pJson.stdout).key.id, "ak_123");
});

test("9. Real Rust launcher routes the 7 launcher-routed subcommands (+ direct admin) to stillfail-station-pion under engine=pion and enforces strict vs fallback for unknown commands", () => {
  const bin = resolvePionBinary();
  const launcher = resolveLauncherBinary();
  const dir = freshDir("launcher-routing");
  const app = join(dir, "app");
  const data = join(dir, "data");
  mkdirSync(join(app, "station"), { recursive: true });
  mkdirSync(data, { recursive: true });
  writeFileSync(join(app, "station", "main.js"), "// dummy\n");
  writeFileSync(join(data, "config.json"), JSON.stringify({ engine: "pion", language: "en" }) + "\n");

  const nodeMarker = join(dir, "node-invoked");
  const fakeNode = join(dir, "fake-node");
  writeFileSync(fakeNode, `#!/bin/sh\necho "$*" > "${nodeMarker}"\nexit 42\n`);
  chmodSync(fakeNode, 0o755);

  const baseEnv = {
    STILLFAIL_STATION_ENGINE: "",
    STILLFAIL_STATION_PION: bin,
    STILLFAIL_NODE: fakeNode,
  };

  // All 7 launcher-routed CLI commands must route to stillfail-station-pion without invoking Node.
  const cmds: Array<{ name: string; args: string[]; expectZero?: boolean }> = [
    { name: "id", args: ["id", "--app", app, "--data", data], expectZero: true },
    { name: "status", args: ["status", "--app", app, "--data", data], expectZero: true },
    { name: "lock", args: ["lock", "status", "--app", app, "--data", data], expectZero: true },
    { name: "channel", args: ["channel", "--app", app, "--data", data], expectZero: true },
    { name: "enroll", args: ["enroll", "--app", app, "--data", data], expectZero: false },
    { name: "update", args: ["update", "--replace-status", "--app", app, "--data", data], expectZero: true },
    { name: "heap", args: ["heap", "--app", app, "--data", data], expectZero: false },
  ];

  // For `heap`, write an immediate answer so it doesn't wait 120s!
  mkdirSync(join(data, "run"), { recursive: true });

  for (const c of cmds) {
    rmSync(nodeMarker, { force: true });
    let responder: ChildProcess | null = null;
    if (c.name === "heap") {
      const reqPath = join(data, "run", "heap.request");
      const ansPath = join(data, "run", "heap.answer");
      responder = spawn(
        process.execPath,
        [
          "-e",
          `const fs = require('node:fs');
const req = ${JSON.stringify(reqPath)};
const ans = ${JSON.stringify(ansPath)};
const end = Date.now() + 8000;
const tick = () => {
  if (fs.existsSync(req)) {
    fs.rmSync(req, { force: true });
    fs.writeFileSync(ans + ".tmp", JSON.stringify({ path: "/tmp/h.pion-heap.json", bytes: 1048576, ms: 5 }));
    fs.renameSync(ans + ".tmp", ans);
    process.exit(0);
  }
  if (Date.now() > end) process.exit(1);
  setTimeout(tick, 15);
};
tick();`,
        ],
        { stdio: "ignore" },
      );
      children.push(responder);
    }
    const r = runBin(launcher, c.args, { ...baseEnv, STILLFAIL_STATION_ENGINE_STRICT: "1" });
    assert.equal(
      existsSync(nodeMarker),
      false,
      `launcher must route '${c.name}' to stillfail-station-pion, NOT Node (status=${r.status}, stderr=${r.stderr})`,
    );
    if (c.expectZero || c.name === "heap") {
      assert.equal(r.status, 0, `launcher '${c.name}' failed: ${r.stderr}`);
    } else {
      assert.equal(r.status, 2, `launcher '${c.name}' without args should exit 2 from Pion CLI: ${r.stderr}`);
    }
  }

  // `admin` is invoked directly on `stillfail-station-pion` (and unknown command exits 2).
  const rAdminHelp = runBin(bin, ["admin", "--help"]);
  assert.equal(rAdminHelp.status, 0, rAdminHelp.stderr);
  assert.match(rAdminHelp.stdout, /Usage: stillfail admin/);
  const rPionUnknown = runBin(bin, ["bogus-cmd"]);
  assert.equal(rPionUnknown.status, 2, "unknown command on stillfail-station-pion must exit 2");

  // Unadvertised command on a Pion binary under engine=pion:
  // - With STILLFAIL_STATION_ENGINE_STRICT=1: explicit error, Node NOT invoked.
  // - Without strict: falls back to Node.
  const partialPion = join(dir, "partial-pion");
  writeFileSync(
    partialPion,
    `#!/bin/sh
if [ "$1" = "--version" ]; then
  echo 'stillfail-station-pion 0.1.0 roles:rig commands:id'
  exit 0
fi
exit 0
`,
  );
  chmodSync(partialPion, 0o755);

  rmSync(nodeMarker, { force: true });
  const rStrict = runBin(launcher, ["status", "--app", app, "--data", data], {
    ...baseEnv,
    STILLFAIL_STATION_PION: partialPion,
    STILLFAIL_STATION_ENGINE_STRICT: "1",
  });
  assert.notEqual(rStrict.status, 0, "unadvertised command in strict mode must fail");
  assert.equal(existsSync(nodeMarker), false, "strict mode must NOT fall back to Node");
  assert.match(rStrict.stderr, /status|command/i, `strict error should explain missing command: ${rStrict.stderr}`);

  rmSync(nodeMarker, { force: true });
  const rFallback = runBin(launcher, ["status", "--app", app, "--data", data], {
    ...baseEnv,
    STILLFAIL_STATION_PION: partialPion,
    STILLFAIL_STATION_ENGINE_STRICT: "",
  });
  assert.equal(existsSync(nodeMarker), true, "non-strict mode must fall back to Node");
  assert.equal(rFallback.status, 42, "fake Node should exit 42 on fallback");
});

test("10. Live Pion rig daemon via real Rust launcher answers heap and channel beta via SIGHUP in <5s", async () => {
  const bin = resolvePionBinary();
  const launcher = resolveLauncherBinary();
  const dir = freshDir("live-rig-cli");
  const app = join(dir, "app");
  const data = join(dir, "data");
  mkdirSync(join(app, "station"), { recursive: true });
  mkdirSync(join(data, "mesh"), { recursive: true });
  writeFileSync(join(app, "station", "main.js"), "// unused under engine=pion\n");
  writeFileSync(join(data, "config.json"), JSON.stringify({ engine: "pion", language: "en", updateChannel: "stable" }) + "\n");

  const ownerKey = edKey();
  const stKey = edKey();
  writeFileSync(
    join(data, "mesh", "cloud.json"),
    JSON.stringify({
      origin: "https://app.still.fail",
      workspace: "ws_live_cli_1",
      workspace_name: "Live CLI WS",
      station: stKey.hex,
      name: "live-rig",
      rig: { owner: "u_live_1", person: ownerKey.hex },
    }),
  );

  const daemon = spawn(launcher, ["run", "--app", app, "--data", data, "--port", "0"], {
    cwd: root,
    stdio: ["ignore", "pipe", "pipe"],
    env: {
      ...process.env,
      STILLFAIL_STATION_ENGINE: "pion",
      STILLFAIL_STATION_ENGINE_STRICT: "1",
      STILLFAIL_STATION_PION: bin,
    },
  });
  children.push(daemon);
  let daemonStderr = "";
  daemon.stderr?.on("data", (c: Buffer) => { daemonStderr += c.toString("utf8"); });

  try {
    // Wait until launcher writes run/station.json (with channel: 1) and daemon writes run/hub.json.
    const stJsonPath = join(data, "run", "station.json");
    const hubJsonPath = join(data, "run", "hub.json");
    const deadline = Date.now() + 15_000;
    while (Date.now() < deadline) {
      if (existsSync(stJsonPath) && existsSync(hubJsonPath)) break;
      await new Promise((r) => setTimeout(r, 50));
    }
    assert.ok(existsSync(stJsonPath), `station.json not written: ${daemonStderr}`);
    assert.ok(existsSync(hubJsonPath), `hub.json not written: ${daemonStderr}`);

    // (a) Real `heap` against live Pion rig daemon must succeed quickly and produce pion-diag-v1 JSON.
    const tHeap = Date.now();
    const heapRes = await runAsync(launcher, ["heap", "--app", app, "--data", data, "--json"], {
      STILLFAIL_STATION_ENGINE: "pion",
      STILLFAIL_STATION_ENGINE_STRICT: "1",
      STILLFAIL_STATION_PION: bin,
    });
    assert.equal(heapRes.status, 0, `live rig heap failed: ${heapRes.stderr}\ndaemon: ${daemonStderr}`);
    assert.ok(Date.now() - tHeap < 5000, "live rig heap should complete in <5s");
    const heapAns = JSON.parse(heapRes.stdout) as { path: string; bytes: number; ms: number };
    assert.ok(existsSync(heapAns.path), `heap snapshot file missing: ${heapAns.path}`);
    const snap = JSON.parse(readFileSync(heapAns.path, "utf8")) as {
      format: string;
      runtime: string;
      rssBytes: number;
      openFds: number;
      uptimeMs: number;
    };
    assert.equal(snap.format, "pion-diag-v1");
    assert.equal(snap.runtime, "pion");
    assert.ok(snap.rssBytes > 0, `expected rssBytes > 0, got ${snap.rssBytes}`);
    assert.ok(snap.openFds > 0, `expected openFds > 0, got ${snap.openFds}`);
    assert.ok(snap.uptimeMs >= 0, `expected uptimeMs >= 0, got ${snap.uptimeMs}`);

    // (b) Real `channel beta` via launcher SIGHUP -> channel-ask -> config.json update.
    const tCh = Date.now();
    const chRes = await runAsync(launcher, ["channel", "beta", "--app", app, "--data", data], {
      STILLFAIL_STATION_ENGINE: "pion",
      STILLFAIL_STATION_ENGINE_STRICT: "1",
      STILLFAIL_STATION_PION: bin,
    });
    assert.equal(chRes.status, 0, `live rig channel beta failed: ${chRes.stderr}\ndaemon: ${daemonStderr}`);
    assert.ok(Date.now() - tCh < 5000, "live rig channel beta should complete in <5s");
    assert.equal(chRes.stdout.trim(), "beta");
    const cfgAfter = JSON.parse(readFileSync(join(data, "config.json"), "utf8")) as { updateChannel?: string };
    assert.equal(cfgAfter.updateChannel, "beta", "config.json must persist updateChannel=beta");
  } finally {
    daemon.kill("SIGTERM");
    await new Promise<void>((resolve) => {
      const t = setTimeout(() => { try { daemon.kill("SIGKILL"); } catch {} resolve(); }, 5000);
      daemon.once("close", () => { clearTimeout(t); resolve(); });
    });
  }
});

test("11. update --replace-prepare resolves relative .tar.gz and .zip paths from caller cwd and rejects FIFO special files", () => {
  const bin = resolvePionBinary();
  const work = freshDir("rel-archive");
  const data = join(work, "data");
  const app = join(work, "app");
  mkdirSync(join(app, "bin"), { recursive: true });
  mkdirSync(join(app, "station"), { recursive: true });
  mkdirSync(data, { recursive: true });
  writeFileSync(join(app, "VERSION"), "0.1.100\n");
  writeFileSync(join(app, "bin", "stillfail"), "#!/bin/sh\necho ok\n");
  writeFileSync(join(app, "station", "main.js"), "// old\n");

  const srcBundle = join(work, "src");
  mkdirSync(join(srcBundle, "stillfail", "bin"), { recursive: true });
  mkdirSync(join(srcBundle, "stillfail", "station"), { recursive: true });
  writeFileSync(join(srcBundle, "stillfail", "bin", "stillfail"), "#!/bin/sh\necho new\n");
  chmodSync(join(srcBundle, "stillfail", "bin", "stillfail"), 0o755);
  writeFileSync(join(srcBundle, "stillfail", "station", "main.js"), "// new\n");

  // Create relative bundle.tar.gz and bundle.zip in `work`
  execFileSync("tar", ["-czf", join(work, "bundle.tar.gz"), "-C", srcBundle, "stillfail"]);
  const hasZip = spawnSync("zip", ["-v"], { stdio: "ignore" }).status === 0;
  if (hasZip) {
    execFileSync("zip", ["-qr", join(work, "bundle.zip"), "stillfail"], { cwd: srcBundle });
  } else {
    execFileSync("python3", [
      "-c",
      `import zipfile, os
with zipfile.ZipFile(${JSON.stringify(join(work, "bundle.zip"))}, "w") as z:
  for dp, _, fns in os.walk(${JSON.stringify(srcBundle)}):
    for f in fns:
      full = os.path.join(dp, f)
      z.write(full, os.path.relpath(full, ${JSON.stringify(srcBundle)}))`,
    ]);
  }

  for (const relName of ["bundle.tar.gz", "bundle.zip"]) {
    const pStage = join(work, `stage-pion-${relName}`);
    const nStage = join(work, `stage-node-${relName}`);
    const pRes = spawnSync(
      bin,
      ["update", "--replace-prepare", "--app", app, "--data", data, "--stage", pStage, "--source", relName],
      { cwd: work, encoding: "utf8", timeout: 20_000 },
    );
    const nRes = spawnSync(
      process.execPath,
      [nodeMain, "update", "--replace-prepare", "--app", app, "--data", data, "--stage", nStage, "--source", relName],
      { cwd: work, encoding: "utf8", timeout: 20_000 },
    );
    assert.equal(pRes.status, 0, `pion relative ${relName} failed: ${pRes.stderr}`);
    assert.equal(nRes.status, 0, `node relative ${relName} failed: ${nRes.stderr}`);
    assert.ok(existsSync(join(pStage, "station", "main.js")), `staged main.js missing for ${relName}`);
  }

  // Special file (FIFO) inside source dir must fail immediately without hanging.
  if (process.platform !== "win32") {
    const fifoSrc = join(work, "fifo-src");
    mkdirSync(join(fifoSrc, "bin"), { recursive: true });
    mkdirSync(join(fifoSrc, "station"), { recursive: true });
    writeFileSync(join(fifoSrc, "bin", "stillfail"), "#!/bin/sh\necho ok\n");
    writeFileSync(join(fifoSrc, "station", "main.js"), "// ok\n");
    execFileSync("mkfifo", [join(fifoSrc, "station", "pipe.fifo")]);
    const fifoStage = join(work, "fifo-stage");
    const t0 = Date.now();
    const fifoRes = runBin(bin, [
      "update",
      "--replace-prepare",
      "--app",
      app,
      "--data",
      data,
      "--stage",
      fifoStage,
      "--source",
      fifoSrc,
    ]);
    assert.notEqual(fifoRes.status, 0, "copy_dir with FIFO must exit non-zero");
    assert.ok(Date.now() - t0 < 5000, "copy_dir with FIFO must fail immediately without hanging");
    assert.match(fifoRes.stderr, /special file|FIFO/i, `unexpected FIFO error: ${fifoRes.stderr}`);
  }
});

test("12. id refuses unreadable secret.key (chmod 0000) without overwriting existing station identity", { skip: process.platform === "win32" || (typeof process.getuid === "function" && process.getuid() === 0) }, () => {
  const bin = resolvePionBinary();
  const data = freshDir("unreadable-key");
  const r1 = runBin(bin, ["id", "--data", data]);
  assert.equal(r1.status, 0, r1.stderr);
  const keyFile = join(data, "mesh", "secret.key");
  const origBytes = readFileSync(keyFile);

  chmodSync(keyFile, 0o000);
  try {
    const r2 = runBin(bin, ["id", "--data", data]);
    assert.notEqual(r2.status, 0, "unreadable secret.key must exit non-zero");
    assert.match(r2.stderr, /EACCES|permission/i, `expected permission error, got: ${r2.stderr}`);
  } finally {
    chmodSync(keyFile, 0o600);
  }
  assert.deepEqual(readFileSync(keyFile), origBytes, "unreadable secret.key must NEVER be overwritten");
});

test("13. admin does not follow 302 redirects (matches Node bin/admin-cli.ts)", async () => {
  const bin = resolvePionBinary();
  const srv = createHttpServer((req, res) => {
    if (req.url === "/v1/admin/me") {
      res.writeHead(302, { Location: "/v1/admin/redirected" });
      res.end();
      return;
    }
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ email: "should-not-follow@example.test" }));
  });
  servers.push(srv);
  await new Promise<void>((resolve) => srv.listen(0, "127.0.0.1", () => resolve()));
  const origin = `http://127.0.0.1:${(srv.address() as { port: number }).port}`;

  const pRes = await runAsync(bin, ["admin", "whoami", "--origin", origin, "--key", "sfa_test_secret_key"]);
  const nRes = await runNodeAdminAsync(["whoami", "--origin", origin, "--key", "sfa_test_secret_key"]);
  assert.equal(pRes.status, 1, `pion admin must reject 302 with exit 1, got stdout=${pRes.stdout}`);
  assert.equal(nRes.status, 1, `node admin must reject 302 with exit 1, got stdout=${nRes.stdout}`);
  assert.match(pRes.stderr, /302/, `pion admin stderr must report 302: ${pRes.stderr}`);
});

test("14. update --replace-prepare handles 240-byte regular filenames identically to Node (no ENAMETOOLONG)", { skip: process.platform === "win32" }, () => {
  const bin = resolvePionBinary();
  const base = freshDir("update-long-name");
  const app = join(base, "app");
  const data = join(base, "data");
  mkdirSync(join(app, "bin"), { recursive: true });
  mkdirSync(join(app, "station"), { recursive: true });
  mkdirSync(data, { recursive: true });
  writeFileSync(join(app, "bin", "stillfail"), "#!/bin/sh\necho ok\n");
  writeFileSync(join(app, "station", "main.js"), "// base\n");
  writeFileSync(join(app, "VERSION"), "1.0.0\n");
  writeFileSync(join(app, "CHANNEL"), "stable\n");

  const longName = "a".repeat(236) + ".txt";
  assert.equal(longName.length, 240);
  const longPayload = Buffer.from("long-filename-atomic-write-parity-payload\n");

  const srcBundle = join(base, "bundle-src");
  mkdirSync(join(srcBundle, "stillfail", "bin"), { recursive: true });
  mkdirSync(join(srcBundle, "stillfail", "station"), { recursive: true });
  writeFileSync(join(srcBundle, "stillfail", "bin", "stillfail"), "#!/bin/sh\necho new\n");
  chmodSync(join(srcBundle, "stillfail", "bin", "stillfail"), 0o755);
  writeFileSync(join(srcBundle, "stillfail", "station", "main.js"), "// updated\n");
  writeFileSync(join(srcBundle, "stillfail", "VERSION"), "1.0.1\n");
  writeFileSync(join(srcBundle, "stillfail", "station", longName), longPayload);

  const tarPath = join(base, "bundle-long.tar.gz");
  execFileSync("tar", ["-czf", tarPath, "-C", srcBundle, "stillfail"]);

  const stageP = join(base, "stage-pion");
  const stageN = join(base, "stage-node");
  const pRes = runBin(bin, ["update", "--replace-prepare", "--app", app, "--data", data, "--stage", stageP, "--source", tarPath]);
  const nRes = runNodeCli(["update", "--replace-prepare", "--app", app, "--data", data, "--stage", stageN, "--source", tarPath]);
  assert.equal(pRes.status, 0, `pion replace-prepare 240B filename failed: ${pRes.stderr}`);
  assert.equal(nRes.status, 0, `node replace-prepare 240B filename failed: ${nRes.stderr}`);

  const pStaged = readFileSync(join(stageP, "station", longName));
  const nStaged = readFileSync(join(stageN, "station", longName));
  assert.deepEqual(pStaged, longPayload);
  assert.deepEqual(pStaged, nStaged);
});
