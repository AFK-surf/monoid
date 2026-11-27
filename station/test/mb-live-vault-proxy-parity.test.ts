// Live MoonBit station parity tests for Vault deep paths:
// 1. Real HTTPS MITM proxy injection (Bearer + Basic auth) & response redaction, unallowed host tunneling,
//    plain HTTP refusal, and expired/revoked grant refusal.
// 2. One-use (`once`) & timed grants across launcher handover and cold station restart + expired grant cleanup.
// 3. Concurrent version races (`PUT /vault/boxes`, `/vault/vaults`, `/vault/items`), atomic vault deletion,
//    `secret_use` ambiguity & duplicate handling, and Unicode / NUL / JSON-path injection defense.
// 4. `kind: "ssh_key"` (`mode: "ssh"` real `SSH_AUTH_SOCK` Ed25519 + RSA signing) & `mode: "file"` temp file delivery + redaction.
// 5. `kind: "browser"` sign-in credential lifecycle (`secret_save` / `secret_use` + `sign_in` MCP tool).
//
// All tests run against the real `stillfail-reader run` binary with no Node on the station's PATH,
// `STILLFAIL_LOCAL_ADMIN=1`, real `/mcp`, real Admin API over loopback iroh mesh, and real local servers.
import assert from "node:assert/strict";
import { type ChildProcess, spawn, spawnSync } from "node:child_process";
import { createPublicKey, generateKeyPairSync, randomBytes, sign as nodeSign, verify as verifySignature } from "node:crypto";
import { createSocket } from "node:dgram";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { createServer as httpServer, request } from "node:http";
import { createServer, type Server } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { DatabaseSync } from "node:sqlite";
import { after, test } from "node:test";
import { type Entry, entryHash, signedBytes as lockBytes } from "../../shared/lock.ts";
import { loadMesh, type Connection, type Stream as MeshStream } from "../src/mesh/native.ts";
import { Reader } from "../src/mesh/wire.ts";
import { mbStationBinary } from "./mb-harness.ts";
import { Store } from "../src/store/store.ts";
import {
  type BoxCert, type Grant, type Item, type Sig, type Vault, TAG, encryptWith, grantContext, itemContext, itemSupersedes, keyContext, newBoxPair, seal, signedBytes, vaultSupersedes,
} from "../src/vault/crypto.ts";
import { GrantKey } from "./fake-control-plane.ts";

const binary = mbStationBinary();
const addon = (() => {
  try {
    return loadMesh();
  } catch {
    return null;
  }
})();

const skipBase = binary === null
  ? "the MoonBit program (stillfail-reader) is not built here"
  : process.platform === "win32"
    ? "the launcher's descriptors are Unix's"
    : false;
const skipMesh = skipBase || (addon === null ? "the mesh addon is not built here (scripts/native.ts run mesh)" : false);

const curlPath = (() => {
  for (const p of ["/usr/bin/curl", "/opt/homebrew/bin/curl", "/usr/local/bin/curl"]) {
    if (existsSync(p)) return p;
  }
  const r = spawnSync("which", ["curl"], { encoding: "utf8" });
  return r.status === 0 && r.stdout.trim() ? r.stdout.trim() : null;
})();

const dirs: string[] = [];
// (short: Unix sockets on macOS are capped at 104 bytes)
const fresh = (what: string) => {
  const dir = mkdtempSync(join(process.platform === "darwin" ? "/tmp" : tmpdir(), `sfvp-${what}-`));
  dirs.push(dir);
  return dir;
};

const children: ChildProcess[] = [];
const cleanups: (() => void)[] = [];

after(async () => {
  for (const fn of cleanups.splice(0)) {
    try { fn(); } catch {}
  }
  const left = children.filter((c) => c.exitCode === null && c.signalCode === null);
  for (const c of left) c.kill("SIGKILL");
  await Promise.race([
    Promise.all(left.map((c) => (c.exitCode === null && c.signalCode === null ? new Promise<void>((r) => c.once("exit", () => r())) : undefined))),
    new Promise((r) => setTimeout(r, 5_000).unref()),
  ]);
  for (const d of dirs) {
    const runners = join(d, "run", "runners");
    if (existsSync(runners)) {
      for (const f of readdirSync(runners)) {
        if (!f.endsWith(".json")) continue;
        try {
          const info = JSON.parse(readFileSync(join(runners, f), "utf8"));
          try { process.kill(-info.pgid, "SIGKILL"); } catch {}
          try { process.kill(info.runner, "SIGKILL"); } catch {}
        } catch {}
      }
    }
    // (a runner killed just above can still write here while it ends: as the other live tests remove theirs)
    rmSync(d, { recursive: true, force: true, maxRetries: 3, retryDelay: 50 });
  }
});

const TOKEN = "vault-proxy-parity-door";

const noNode = (more: Record<string, string> = {}) => ({
  PATH: fresh("path"),
  HOME: process.env.HOME ?? tmpdir(),
  TMPDIR: tmpdir(),
  STILLFAIL_TEST_UI_ASK: TOKEN,
  STILLFAIL_HELD_EVERY_MS: "300",
  STILLFAIL_NO_DISCOVERY: "1",
  ...more,
});

type Launched = {
  child: ChildProcess;
  next: (what: string, ok: (m: any) => boolean) => Promise<any>;
  tell: (m: unknown) => void;
  ended: Promise<number | null>;
  err: () => string;
};

async function launch(data: string, app: string, more: Record<string, string> = {}): Promise<Launched> {
  const listener = () => new Promise<Server>((resolve) => {
    const s = createServer();
    s.listen(0, "127.0.0.1", () => resolve(s));
  });
  const [mcp, loop] = [await listener(), await listener()];
  const fd = (s: Server) => (s as any)._handle.fd as number;
  const child = spawn(binary!, ["run", "--app", app, "--data", data, "--launcher-fds", "3,4,5", "--launcher-carries", "--launcher-heartbeat"], {
    stdio: ["ignore", "pipe", "pipe", fd(mcp), fd(loop), "pipe"],
    env: noNode(more),
  });
  children.push(child);
  mcp.close();
  loop.close();
  const said: any[] = [];
  const waiters: (() => void)[] = [];
  const channel = (child.stdio as readonly unknown[])[5] as import("node:net").Socket;
  createInterface({ input: channel }).on("line", (line) => {
    said.push(JSON.parse(line));
    for (const w of waiters.splice(0)) w();
  });
  let err = "";
  child.stderr!.on("data", (d) => (err += d));
  const next = (what: string, ok: (m: any) => boolean) =>
    new Promise<any>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`never said: ${what}; said ${JSON.stringify(said)}; stderr ${err}`)), 20_000);
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
  return { child, next, tell: (m) => channel.write(`${JSON.stringify(m)}\n`), ended, err: () => err };
}

async function given<T>(what: string, f: () => T | null | undefined | false | Promise<T | null | undefined | false>, ms = 20_000): Promise<T> {
  const until = Date.now() + ms;
  let last: unknown = null;
  for (;;) {
    try {
      const v = await f();
      if (v !== null && v !== undefined && v !== false) return v as T;
    } catch (e) {
      last = e;
    }
    if (Date.now() > until) throw new Error(`never came: ${what}${last ? ` (${(last as Error).message})` : ""}`);
    await new Promise((r) => setTimeout(r, 50));
  }
}

function http(port: number, path: string, o: { method?: string; body?: string; headers?: Record<string, string> } = {}): Promise<{ status: number; body: string }> {
  return new Promise((resolve, reject) => {
    const req = request({
      host: "127.0.0.1",
      port,
      path,
      method: o.method ?? (o.body === undefined ? "GET" : "POST"),
      headers: { "content-type": "application/json", ...o.headers },
    }, (res) => {
      let text = "";
      res.on("data", (d) => (text += d));
      res.on("end", () => resolve({ status: res.statusCode!, body: text }));
    });
    req.on("error", reject);
    req.end(o.body);
  });
}

async function tool(port: number, token: string, name: string, args: unknown = {}): Promise<{ text: string; error: boolean }> {
  const r = await http(port, "/mcp", {
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name, arguments: args } }),
    headers: { authorization: `Bearer ${token}` },
  });
  assert.equal(r.status, 200, r.body);
  const result = JSON.parse(r.body).result;
  return { text: result.content.map((c: any) => c.text).join("\n"), error: result.isError === true };
}

function stationId(data: string): string {
  const r = spawnSync(binary!, ["id", "--data", data], { env: noNode(), encoding: "utf8" });
  assert.equal(r.status, 0, r.stderr);
  return r.stdout.trim();
}

async function freeUdpPort(): Promise<number> {
  const socket = createSocket("udp4");
  await new Promise<void>((r) => socket.bind(0, "127.0.0.1", () => r()));
  const port = socket.address().port;
  await new Promise<void>((r) => socket.close(() => r()));
  return port;
}

const line = (stream: MeshStream, value: unknown) => stream.write(Buffer.from(JSON.stringify(value) + "\n"));

async function member(conn: Connection, credential: string) {
  const first = await conn.openBi();
  await line(first, { credential, protocol: 2 });
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

const openStore = (data: string) => Store.open(join(data, "stillfail.db"), join(data, "archive"), { currentTimeMillisUnsafe: () => Date.now() } as never);

function ed() {
  const key = generateKeyPairSync("ed25519").privateKey;
  const hex = Buffer.from(createPublicKey(key).export({ format: "jwk" }).x as string, "base64url").toString("hex");
  return { hex, id: `ed25519:${hex}`, sign: (bytes: Buffer) => nodeSign(null, bytes, key).toString("hex") };
}
type Key = ReturnType<typeof ed>;

function signed<T extends Record<string, unknown>>(o: T, tag: string, key: Key): T & { sig: Sig } {
  return { ...o, sig: { key: key.id, alg: "Ed25519", sig: key.sign(signedBytes(o, tag)) } };
}

const fill = (b: number, n = 32) => new Uint8Array(n).fill(b);

const extractReqId = (text: string): string => {
  const m = text.match(/r_[0-9A-Z]{26}/);
  assert.ok(m, `expected request id r_… in tool output: ${text}`);
  return m[0]!;
};

async function setupLockedStation(opts: {
  ws: string;
  vaultId: string;
  tag: string;
  extraEnv?: Record<string, string>;
  extraMembers?: { sub: string; email: string; role: "owner" | "admin" | "member" }[];
}) {
  const data = fresh(opts.tag);
  const app = fresh("app");
  const work = fresh("work");
  writeFileSync(join(app, "BUILD"), "9500\n");
  const id = stationId(data);
  const grant = new GrantKey();
  const meshPort = await freeUdpPort();

  const client = await addon!.bind({ secretKey: randomBytes(32), alpns: [Buffer.from("client/1")], relayUrls: [], discovery: false, bindAddr: "127.0.0.1:0" });
  cleanups.push(() => client.close());

  const aliceSigner = ed();
  const aliceBox = newBoxPair();
  const vaultKey = fill(17);
  const members = [{ sub: "alice", email: "alice@x.com", role: "owner" as const }, ...(opts.extraMembers ?? [])];
  const genesisBody = {
    owner: "alice",
    origins: ["https://app.still.fail"],
    rp_id: "app.still.fail",
    cloud_keys: { keys: [grant.jwk] },
    members,
    devices: [{ id: client.id(), sub: "alice", kind: "app", label: "alice-app", sign_key: aliceSigner.id }],
    passkeys: [],
    stations: [{ key: id, name: "here" }],
    gateways: [],
  };
  const ge = { v: 1, ws: opts.ws, seq: 0, prev: null, at: 1000, kind: "genesis", body: genesisBody } as Omit<Entry, "sig">;
  const genesisEntry: Entry = {
    ...ge,
    sig: { key: aliceSigner.id, alg: "Ed25519" as const, sig: aliceSigner.sign(lockBytes(entryHash(ge as Entry))) },
  };

  mkdirSync(join(data, "mesh"), { recursive: true });
  writeFileSync(join(data, "mesh", "cloud.json"), JSON.stringify({
    origin: "http://127.0.0.1:9",
    station: id,
    workspace: opts.ws,
    workspace_name: "Team",
    name: "here",
    relay_url: "",
    relay_urls: [],
    grant_keys: { keys: [grant.jwk] },
    peers: [],
    revocations: [],
  }));
  writeFileSync(join(data, "mesh", "lock.json"), JSON.stringify({ entries: [genesisEntry] }));

  const s = openStore(data);
  s.insertSession({ key: "s1", connect: "chat", runtime: "claude", profile: "cc", workspace: work, token: "t1", createdBy: "alice@x.com", ws: opts.ws, createdAt: Date.now(), lastActiveAt: Date.now() });
  const thread = s.openThread("chat", "CHAT", "1795000000.001000", opts.tag, "alice@x.com").id;
  s.joinThread(thread, "s1", "chat");
  s.close();

  const launched = await launch(data, app, {
    STILLFAIL_LOCAL_ADMIN: "1",
    STILLFAIL_MESH_BIND_ADDR: `127.0.0.1:${meshPort}`,
    ...(opts.extraEnv ?? {}),
  });
  await launched.next("ready", (m) => m.ready === true);
  const door = (await launched.next("mcp", (m) => m.serving === "mcp")).port as number;

  const now = Math.floor(Date.now() / 1000);
  const cred = grant.credential(
    { typ: "stillfail-member+jwt" },
    { iss: "stillfail-cloud", sub: "alice", email: "alice@x.com", name: "Alice", ws: opts.ws, role: "owner", device: client.id(), sid: `s-${opts.tag}`, iat: now, exp: now + 3600 },
  );
  const conn = await given("connected to station over mesh", () => client.connect({ id, ips: [`127.0.0.1:${meshPort}`] }, Buffer.from("stillfail/admin/1")));
  assert.equal((await member(conn, cred)).ok, true);

  const cert: BoxCert = signed({ v: 1 as const, ws: opts.ws, device: client.id(), box: aliceBox.pub, at: now }, TAG.box, aliceSigner);
  assert.equal((await memberAsk(conn, "PUT", "/admin/api/vault/boxes", cert))[0], 200);
  const vault: Vault = signed({
    v: 1 as const,
    ws: opts.ws,
    id: opts.vaultId,
    seq: 0,
    owner: "alice",
    name: "Personal",
    members: ["alice"],
    epoch: 0,
    keys: [{ cert, wrapped: seal(aliceBox.pub, vaultKey, keyContext(opts.ws, opts.vaultId, 0)) }],
    at: now,
  }, TAG.vault, aliceSigner);
  assert.equal((await memberAsk(conn, "PUT", "/admin/api/vault/vaults", vault))[0], 200);

  return { data, app, work, id, meshPort, grant, client, conn, aliceSigner, aliceBox, vaultKey, cert, vault, launched, door, thread, now };
}

test("Vault HTTPS MITM proxy: Bearer & Basic injection, response redaction, unallowed host tunneling, plain HTTP refusal, expired & revoked grant refusal", { skip: skipMesh || (!curlPath ? "curl not found" : false) }, async () => {
  const WS = "01HZZZZZZZZZZZZZZZZZZZZP01";
  const VAULT = "v_01HZZZZZZZZZZZZZZZZZZZZP01";
  const SECRET_VAL = "ghp_proxy_s3cr3t_9876543210";

  // Local upstream HTTP server that records headers AND echoes the secret back to verify response redaction.
  const seen: { url: string; auth: string }[] = [];
  const upstream = httpServer((req, res) => {
    const auth = String(req.headers.authorization ?? "");
    seen.push({ url: req.url ?? "", auth });
    let decoded = "";
    if (auth.startsWith("Basic ")) {
      decoded = Buffer.from(auth.slice(6), "base64").toString("utf8");
    }
    res.writeHead(200, { "content-type": "text/plain" });
    res.end(`upstream-ok path=${req.url} auth=${auth} decoded=${decoded}`);
  });
  await new Promise<void>((r) => upstream.listen(0, "127.0.0.1", () => r()));
  cleanups.push(() => upstream.close());
  const upPort = (upstream.address() as any).port as number;

  // Local TCP echo server to test unallowed-host raw CONNECT tunneling (no MITM, no secret swap).
  const echo = createServer((sock) => sock.on("data", (d) => sock.write(Buffer.concat([Buffer.from("echo:"), d]))));
  await new Promise<void>((r) => echo.listen(0, "127.0.0.1", () => r()));
  cleanups.push(() => echo.close());
  const echoPort = (echo.address() as any).port as number;

  const env = await setupLockedStation({
    ws: WS,
    vaultId: VAULT,
    tag: "proxy",
    extraEnv: { STILLFAIL_TEST_PROXY_UPSTREAM: String(upPort) },
  });

  // 1) Save proxy-mode token via secret_save and approve with immediate proxy grant.
  const saveRes = await tool(env.door, "t1", "secret_save", {
    kind: "token",
    name: "Proxy API Token",
    about: "MITM proxy test token",
    modes: ["proxy"],
    hosts: ["api.example.test"],
    env: "API_TOK",
    reason: "save proxy token for MITM test",
  });
  assert.equal(saveRes.error, false, saveRes.text);
  const saveReqId = extractReqId(saveRes.text);

  const [reqsStatus, reqsBody] = await memberAsk(env.conn, "GET", "/admin/api/vault/requests");
  assert.equal(reqsStatus, 200);
  const saveReq = reqsBody.requests.find((r: any) => r.id === saveReqId);
  assert.ok(saveReq, `missing saveReq ${saveReqId}`);

  const plainPayload = { kind: "token" as const, name: "Proxy API Token", fields: { value: SECRET_VAL }, domains: ["api.example.test"], notes: "MITM proxy test token" };
  const makeItem = (version: number, deleted = false): Item => signed({
    v: 1 as const,
    ws: WS,
    vault: VAULT,
    id: saveReq.item,
    version,
    epoch: 0,
    ct: deleted ? "" : encryptWith(env.vaultKey, Buffer.from(JSON.stringify(plainPayload)), itemContext(WS, VAULT, saveReq.item, version, 0), fill(30 + version, 12)),
    ...(deleted ? { deleted: true as const } : { listing: { name: "Proxy API Token", about: "MITM proxy test token", kind: "token" as const, modes: ["proxy" as const], hosts: ["api.example.test"], env: "API_TOK" } }),
    at: env.now + version,
  }, TAG.item, env.aliceSigner);

  assert.equal((await memberAsk(env.conn, "PUT", "/admin/api/vault/items", makeItem(0)))[0], 200);
  const saveGrant: Grant = signed({
    v: 1 as const,
    ws: WS,
    request: saveReqId,
    vault: VAULT,
    item: saveReq.item,
    mode: "proxy" as const,
    hosts: ["api.example.test"],
    scope: "chat" as const,
    exp: env.now + 3600,
    secret: seal(saveReq.box, Buffer.from(JSON.stringify(plainPayload)), grantContext(WS, saveReqId)),
    at: env.now,
  }, TAG.grant, env.aliceSigner);
  const [savedStatus, savedBody] = await memberAsk(env.conn, "POST", "/admin/api/vault/saves", { request: saveReqId, vault: VAULT, grant: saveGrant });
  assert.equal(savedStatus, 200, JSON.stringify(savedBody));

  // 2) Run secret_run with curl: check env placeholder, Bearer injection + response redaction, Basic injection + response redaction, and plain HTTP refusal.
  const envOut = join(env.work, "proxy-env.json");
  const runBearer = await tool(env.door, "t1", "secret_run", {
    grant: saveReqId,
    command: `printf '{"tok":"%s","sec":"%s","proxy":"%s","ca":"%s"}' "$API_TOK" "$STILLFAIL_SECRET" "$HTTPS_PROXY" "$SSL_CERT_FILE" > "${envOut}" && "${curlPath}" -sS -H "Authorization: Bearer $API_TOK" https://api.example.test/bearer`,
  });
  assert.equal(runBearer.error, false, runBearer.text);
  const subEnv = JSON.parse(readFileSync(envOut, "utf8"));
  assert.equal(subEnv.tok, `stillfail-secret:${saveReqId}`, "subprocess must only see placeholder, never real secret");
  assert.equal(subEnv.sec, `stillfail-secret:${saveReqId}`);
  assert.match(subEnv.proxy, /^http:\/\/run:[^@]+@127\.0\.0\.1:\d+$/);
  assert.ok(existsSync(subEnv.ca), "CA bundle file must exist");
  assert.equal(seen.length, 1);
  assert.equal(seen[0]!.url, "/bearer");
  assert.equal(seen[0]!.auth, `Bearer ${SECRET_VAL}`, "proxy must inject real secret on allowed HTTPS host");
  assert.ok(!runBearer.text.includes(SECRET_VAL), `secret_run output must redact echoed secret: ${runBearer.text}`);
  assert.match(runBearer.text, /upstream-ok path=\/bearer/);

  const runBasic = await tool(env.door, "t1", "secret_run", {
    grant: saveReqId,
    command: `"${curlPath}" -sS -u "octocat:$API_TOK" https://api.example.test/basic`,
  });
  assert.equal(runBasic.error, false, runBasic.text);
  assert.equal(seen.length, 2);
  assert.equal(seen[1]!.url, "/basic");
  assert.equal(seen[1]!.auth, `Basic ${Buffer.from(`octocat:${SECRET_VAL}`).toString("base64")}`, "proxy must swap placeholder inside Basic auth");
  assert.ok(!runBasic.text.includes(SECRET_VAL), `secret_run must redact Basic echoed secret: ${runBasic.text}`);

  // 3) Plain HTTP request to proxy is refused (405 Method Not Allowed), and unallowed host CONNECT tunnels without swapping placeholder.
  const probeScript = join(env.work, "proxy-probe.mjs");
  writeFileSync(probeScript, `
    import { connect } from "node:net";
    const u = new URL(process.env.HTTPS_PROXY);
    const auth = Buffer.from(u.username + ":" + u.password).toString("base64");
    const placeholder = process.env.API_TOK;
    // Plain HTTP request directly to proxy
    const plainStatus = await new Promise((resolve, reject) => {
      const s = connect(Number(u.port), "127.0.0.1", () => {
        s.write("GET http://api.example.test/plain HTTP/1.1\\r\\nhost: api.example.test\\r\\nproxy-authorization: Basic " + auth + "\\r\\n\\r\\n");
      });
      let data = "";
      s.on("data", (d) => (data += d.toString("latin1")));
      s.on("end", () => resolve(data.split("\\r\\n")[0]));
      s.on("close", () => resolve(data.split("\\r\\n")[0]));
      s.on("error", reject);
    });
    // CONNECT to unallowed host (local echo server) -> raw tunnel, placeholder NOT swapped
    const echoed = await new Promise((resolve, reject) => {
      const s = connect(Number(u.port), "127.0.0.1", () => {
        s.write("CONNECT 127.0.0.1:${echoPort} HTTP/1.1\\r\\nproxy-authorization: Basic " + auth + "\\r\\n\\r\\n");
      });
      let buf = "";
      let established = false;
      s.on("data", (d) => {
        buf += d.toString("utf8");
        if (!established && buf.includes("\\r\\n\\r\\n")) {
          established = true;
          s.write(placeholder);
        }
        if (buf.includes("echo:")) {
          s.end();
          resolve(buf.slice(buf.indexOf("echo:")));
        }
      });
      s.on("error", reject);
    });
    process.stdout.write(JSON.stringify({ plainStatus, echoed }));
  `);
  const probeOut = join(env.work, "probe-result.json");
  const runProbe = await tool(env.door, "t1", "secret_run", {
    grant: saveReqId,
    command: `"${process.execPath}" "${probeScript}" > "${probeOut}"`,
  });
  assert.equal(runProbe.error, false, runProbe.text);
  const probe = JSON.parse(readFileSync(probeOut, "utf8"));
  assert.match(probe.plainStatus, /^HTTP\/1\.1 405/, `plain HTTP must be refused: ${JSON.stringify(probe)}`);
  assert.equal(probe.echoed, `echo:stillfail-secret:${saveReqId}`, "unallowed host must tunnel raw placeholder without swapping secret");

  // 4) Expired grant refused by Admin API, and revoked/deleted item stops future secret_use & revokes access.
  const useExpRes = await tool(env.door, "t1", "secret_use", {
    item: "Proxy API Token",
    mode: "proxy",
    reason: "test expired grant rejection",
  });
  assert.equal(useExpRes.error, false, useExpRes.text);
  const expReqId = extractReqId(useExpRes.text);
  const [, reqs2Body] = await memberAsk(env.conn, "GET", "/admin/api/vault/requests");
  const expReq = reqs2Body.requests.find((r: any) => r.id === expReqId);
  assert.ok(expReq);
  const expiredGrant: Grant = signed({
    v: 1 as const,
    ws: WS,
    request: expReqId,
    vault: VAULT,
    item: saveReq.item,
    mode: "proxy" as const,
    hosts: ["api.example.test"],
    scope: "hour" as const,
    exp: env.now - 120,
    secret: seal(expReq.box, Buffer.from(JSON.stringify(plainPayload)), grantContext(WS, expReqId)),
    at: env.now - 200,
  }, TAG.grant, env.aliceSigner);
  const [expStatus, expBody] = await memberAsk(env.conn, "POST", "/admin/api/vault/grants", expiredGrant);
  assert.equal(expStatus, 409, `already-expired grant must be refused: ${JSON.stringify(expBody)}`);

  // Delete item via secret_delete -> approves atomically -> secret_use fails & secret_run on revoked grant fails.
  const delRes = await tool(env.door, "t1", "secret_delete", { item: "Proxy API Token", reason: "decommission proxy token" });
  assert.equal(delRes.error, false, delRes.text);
  const delReqId = extractReqId(delRes.text);
  assert.equal((await memberAsk(env.conn, "PUT", "/admin/api/vault/items", makeItem(1, true)))[0], 200);
  const [remStatus, remBody] = await memberAsk(env.conn, "POST", "/admin/api/vault/removed", { request: delReqId });
  assert.equal(remStatus, 200, JSON.stringify(remBody));

  const useAfterDel = await tool(env.door, "t1", "secret_use", { item: "Proxy API Token", mode: "proxy", reason: "after delete" });
  assert.equal(useAfterDel.error, true, "secret_use must fail after item deletion");

  assert.doesNotMatch(env.launched.err(), /SQLITE_BUSY|database is locked|unknown op|no hub call/i);
  env.launched.tell({ op: "stop" });
  assert.equal(await env.launched.ended, 0, env.launched.err());
});

test("Vault once & timed grants: handover carry preserves chat grant and prevents once double-spend; cold restart restores valid plain grants and purges expired ones", { skip: skipMesh }, async () => {
  // Part A: Locked vault handover carry (chat grant survives; unspent once grant spends exactly once after handover; spent once grant stays spent).
  const WS = "01HZZZZZZZZZZZZZZZZZZZZP02";
  const VAULT = "v_01HZZZZZZZZZZZZZZZZZZZZP02";
  const SECRET_VAL = "handover-s3cr3t-value-42";
  const env = await setupLockedStation({ ws: WS, vaultId: VAULT, tag: "handover" });

  const itemId = "i_01HZZZZZZZZZZZZZZZZZZZZP02";
  const plainPayload = { kind: "token" as const, name: "Handover Token", fields: { value: SECRET_VAL }, domains: [], notes: "handover test" };
  const item: Item = signed({
    v: 1 as const,
    ws: WS,
    vault: VAULT,
    id: itemId,
    version: 0,
    epoch: 0,
    ct: encryptWith(env.vaultKey, Buffer.from(JSON.stringify(plainPayload)), itemContext(WS, VAULT, itemId, 0, 0), fill(41, 12)),
    listing: { name: "Handover Token", about: "handover test", kind: "token" as const, modes: ["env" as const], hosts: [], env: "HO_TOK" },
    at: env.now,
  }, TAG.item, env.aliceSigner);
  assert.equal((await memberAsk(env.conn, "PUT", "/admin/api/vault/items", item))[0], 200);

  const askAndGrant = async (scope: "once" | "chat", reason: string) => {
    const r = await tool(env.door, "t1", "secret_use", { item: "Handover Token", mode: "env", reason });
    assert.equal(r.error, false, r.text);
    const reqId = extractReqId(r.text);
    const [, reqs] = await memberAsk(env.conn, "GET", "/admin/api/vault/requests");
    const req = reqs.requests.find((x: any) => x.id === reqId);
    assert.ok(req);
    const g: Grant = signed({
      v: 1 as const,
      ws: WS,
      request: reqId,
      vault: VAULT,
      item: itemId,
      mode: "env" as const,
      hosts: [],
      scope,
      ...(scope === "once" ? {} : { timeout: { kind: "fixed" as const, seconds: 3600 } }),
      exp: env.now + 3600,
      secret: seal(req.box, Buffer.from(JSON.stringify(plainPayload)), grantContext(WS, reqId)),
      at: env.now,
    }, TAG.grant, env.aliceSigner);
    const [st, body] = await memberAsk(env.conn, "POST", "/admin/api/vault/grants", g);
    assert.equal(st, 200, JSON.stringify(body));
    return reqId;
  };

  const chatGrantId = await askAndGrant("chat", "reusable across handover");
  const unspentOnceId = await askAndGrant("once", "unspent before handover");
  const spentOnceId = await askAndGrant("once", "spent before handover");

  // Spend `spentOnceId` BEFORE handover.
  const preSpend = await tool(env.door, "t1", "secret_run", { grant: spentOnceId, command: "printf pre-spend-ok" });
  assert.equal(preSpend.error, false, preSpend.text);
  const preSecond = await tool(env.door, "t1", "secret_run", { grant: spentOnceId, command: "printf should-fail" });
  assert.equal(preSecond.error, true, "spent once grant must refuse second run before handover");

  // Perform real launcher handover from station A to station B.
  const b = await launch(env.data, env.app, { STILLFAIL_LOCAL_ADMIN: "1", STILLFAIL_MESH_BIND_ADDR: `127.0.0.1:${await freeUdpPort()}` });
  await b.next("ready", (m) => m.ready === true);
  env.launched.tell({ op: "handover" });
  const carry = await env.launched.next("carry", (m) => m.carry !== undefined);
  assert.equal(await env.launched.ended, 0, env.launched.err());
  b.tell({ op: "carried", carried: carry.carry });
  const bDoor = (await b.next("b mcp", (m) => m.serving === "mcp")).port as number;

  // On station B:
  // 1. `spentOnceId` must STILL be unusable (no double-spend across handover).
  const postSpent = await tool(bDoor, "t1", "secret_run", { grant: spentOnceId, command: "printf should-still-fail" });
  assert.equal(postSpent.error, true, `spent once grant must remain spent after handover: ${postSpent.text}`);

  // 2. `unspentOnceId` must work ONCE on station B, then fail on the second call.
  const outB1 = join(env.work, "b-once.txt");
  const postOnce1 = await tool(bDoor, "t1", "secret_run", { grant: unspentOnceId, command: `printf '%s' "$HO_TOK" > "${outB1}" && printf 'ok:%s' "$HO_TOK"` });
  assert.equal(postOnce1.error, false, postOnce1.text);
  assert.equal(readFileSync(outB1, "utf8"), SECRET_VAL);
  assert.ok(!postOnce1.text.includes(SECRET_VAL), "output must be redacted after handover");
  const postOnce2 = await tool(bDoor, "t1", "secret_run", { grant: unspentOnceId, command: "printf second-once" });
  assert.equal(postOnce2.error, true, `once grant must refuse second use after handover: ${postOnce2.text}`);

  // 3. `chatGrantId` remains reusable on station B.
  const postChat1 = await tool(bDoor, "t1", "secret_run", { grant: chatGrantId, command: "printf chat-1" });
  assert.equal(postChat1.error, false, postChat1.text);
  const postChat2 = await tool(bDoor, "t1", "secret_run", { grant: chatGrantId, command: "printf chat-2" });
  assert.equal(postChat2.error, false, postChat2.text);

  b.tell({ op: "stop" });
  assert.equal(await b.ended, 0, b.err());

  // Part B: Plain library cold restart (no handover carry) — restores valid plain grants & cleans expired grants at startup.
  const pData = fresh("plain-restart");
  const pApp = fresh("app");
  const pWork = fresh("pwork");
  writeFileSync(join(pApp, "BUILD"), "9500\n");
  const PWS = "ws-plain-restart";
  const ps = openStore(pData);
  ps.insertSession({ key: "sp1", connect: "chat", runtime: "claude", profile: "cc", workspace: pWork, token: "tp1", createdBy: "owner@local", ws: PWS, createdAt: Date.now(), lastActiveAt: Date.now() });
  const pThread = ps.openThread("chat", "CHAT", "1795000000.002000", "plain restart", "owner@local").id;
  ps.joinThread(pThread, "sp1", "chat");
  ps.close();

  // Launch station C once to initialize vault schema, then stop cleanly.
  const c = await launch(pData, pApp, { STILLFAIL_LOCAL_ADMIN: "1" });
  await c.next("ready", (m) => m.ready === true);
  c.tell({ op: "stop" });
  assert.equal(await c.ended, 0, c.err());

  // Seed a plain library item, a valid hour grant, a valid once grant, and an expired grant in SQLite before cold restart.
  const pNow = Math.floor(Date.now() / 1000);
  const pHourId = "r_01HZZZZZZZZZZZZZZZZZZPH1";
  const pOnceId = "r_01HZZZZZZZZZZZZZZZZZZPO1";
  const pExpId = "r_01HZZZZZZZZZZZZZZZZZZPE1";
  const pdb = new DatabaseSync(join(pData, "stillfail.db"));
  // (a station's own writes may hold the database's lock: wait for it, as every connection to it does)
  pdb.exec("PRAGMA busy_timeout = 5000;");
  try {
    const plainItem = {
      ws: PWS,
      id: "ip1",
      owner: "owner@local",
      version: 0,
      kind: "token",
      name: "Plain Restart Token",
      fields: { value: "plain-restart-secret-777" },
      notes: "survives restart",
      listing: { name: "Plain Restart Token", kind: "token", modes: ["env"], hosts: [], env: "PLAIN_TOK" },
      at: pNow - 10,
    };
    pdb.prepare("INSERT INTO vault_plain (ws, id, owner, version, body) VALUES (?, ?, ?, ?, ?)").run(PWS, "ip1", "owner@local", 0, JSON.stringify(plainItem));
    const seedGrant = (id: string, scope: "hour" | "once", exp: number, at: number) => {
      const req = { id, ws: PWS, vault: "plain", item: "ip1", session: "sp1", chat: "CHAT/1795000000.002000", owner: "owner@local", mode: "env", reason: scope, box: "", at, status: "granted" };
      const gr = { v: 1, ws: PWS, request: id, vault: "plain", item: "ip1", mode: "env", hosts: [], scope, exp, at };
      pdb.prepare("INSERT INTO vault_grants (ws, id, session, body) VALUES (?, ?, ?, ?)").run(PWS, id, "sp1", JSON.stringify({ request: req, grant: gr, uses: 0 }));
    };
    seedGrant(pHourId, "hour", pNow + 3600, pNow - 10);
    seedGrant(pOnceId, "once", pNow + 3600, pNow - 10);
    seedGrant(pExpId, "hour", pNow - 3600, pNow - 7200);
  } finally {
    pdb.close();
  }

  // Cold restart on the same data directory.
  const d = await launch(pData, pApp, { STILLFAIL_LOCAL_ADMIN: "1" });
  await d.next("ready", (m) => m.ready === true);
  const dDoor = (await d.next("mcp", (m) => m.serving === "mcp")).port as number;

  // Verify expired grant was purged at startup.
  const pdbCheck = new DatabaseSync(join(pData, "stillfail.db"), { readOnly: true });
  try {
    const row = pdbCheck.prepare("SELECT id FROM vault_grants WHERE ws = ? AND id = ?").get(PWS, pExpId);
    assert.equal(row, undefined, "expired grant row must be purged on startup");
  } finally {
    pdbCheck.close();
  }

  // Valid hour grant restored and usable (with redaction); once grant usable once then refused.
  const pOut = join(pWork, "plain-restored.txt");
  const dHour = await tool(dDoor, "tp1", "secret_run", { grant: pHourId, command: `printf '%s' "$PLAIN_TOK" > "${pOut}" && printf 'echo:%s' "$PLAIN_TOK"` });
  assert.equal(dHour.error, false, dHour.text);
  assert.equal(readFileSync(pOut, "utf8"), "plain-restart-secret-777");
  assert.ok(!dHour.text.includes("plain-restart-secret-777"), "restored plain grant output must be redacted");

  const dOnce1 = await tool(dDoor, "tp1", "secret_run", { grant: pOnceId, command: "printf once-restored-1" });
  assert.equal(dOnce1.error, false, dOnce1.text);
  const dOnce2 = await tool(dDoor, "tp1", "secret_run", { grant: pOnceId, command: "printf once-restored-2" });
  assert.equal(dOnce2.error, true, `restored once grant must not run twice: ${dOnce2.text}`);

  d.tell({ op: "stop" });
  assert.equal(await d.ended, 0, d.err());
});

test("Vault concurrency & guards: PUT box/vault/item version races, atomic vault deletion, secret_use ambiguity, Unicode names & NUL/JSON-path injection defense", { skip: skipMesh }, async () => {
  const WS = "01HZZZZZZZZZZZZZZZZZZZZP03";
  const VAULT1 = "v_01HZZZZZZZZZZZZZZZZZZZZP03";
  const VAULT2 = "v_01HZZZZZZZZZZZZZZZZZZZZP04";
  const env = await setupLockedStation({
    ws: WS,
    vaultId: VAULT1,
    tag: "races",
    extraMembers: [{ sub: "bob", email: "bob@x.com", role: "member" }],
  });

  // 1) Box certificate timestamp ordering: newer overwrites older, stale never overwrites newer, same timestamp last-write wins.
  const boxA = newBoxPair();
  const boxB = newBoxPair();
  const boxC = newBoxPair();
  const certNewer: BoxCert = signed({ v: 1 as const, ws: WS, device: env.client.id(), box: boxA.pub, at: env.now + 50 }, TAG.box, env.aliceSigner);
  const certStale: BoxCert = signed({ v: 1 as const, ws: WS, device: env.client.id(), box: boxB.pub, at: env.now + 10 }, TAG.box, env.aliceSigner);
  const certSameTs: BoxCert = signed({ v: 1 as const, ws: WS, device: env.client.id(), box: boxC.pub, at: env.now + 50 }, TAG.box, env.aliceSigner);

  assert.equal((await memberAsk(env.conn, "PUT", "/admin/api/vault/boxes", certNewer))[0], 200);
  const [staleSt, staleBody] = await memberAsk(env.conn, "PUT", "/admin/api/vault/boxes", certStale);
  assert.equal(staleSt, 200);
  assert.equal(staleBody.box.box, boxA.pub, "stale box cert must not overwrite newer cert");
  const [sameSt, sameBody] = await memberAsk(env.conn, "PUT", "/admin/api/vault/boxes", certSameTs);
  assert.equal(sameSt, 200);
  assert.equal(sameBody.box.box, boxC.pub, "same-timestamp box cert updates via last-write");

  // 2) Concurrent PUT /vault/vaults at seq 1: exactly one wins (200) and the other gets 409 vault_conflict; copy=1 resolves deterministically.
  const makeVault = (id: string, seq: number, name: string, extra: Partial<Vault> = {}): Vault => signed({
    v: 1 as const,
    ws: WS,
    id,
    seq,
    owner: "alice",
    name,
    members: ["alice"],
    epoch: 0,
    keys: [{ cert: certSameTs, wrapped: seal(boxC.pub, env.vaultKey, keyContext(WS, id, extra.epoch ?? 0)) }],
    at: env.now + seq,
    ...extra,
  }, TAG.vault, env.aliceSigner);

  const v1A = makeVault(VAULT1, 1, "Branch Alpha");
  const v1B = makeVault(VAULT1, 1, "Branch Zulu");
  const [rA, rB] = await Promise.all([
    memberAsk(env.conn, "PUT", "/admin/api/vault/vaults", v1A),
    memberAsk(env.conn, "PUT", "/admin/api/vault/vaults", v1B),
  ]);
  const statuses = [rA[0], rB[0]].sort();
  assert.deepEqual(statuses, [200, 409], `concurrent vault seq=1 must yield one 200 and one 409: ${JSON.stringify([rA, rB])}`);
  const loser = rA[0] === 409 ? rA[1] : rB[1];
  assert.equal(loser.code, "vault_conflict");

  // copy=1 with superseding sibling converges deterministically.
  const [vWinner] = vaultSupersedes(v1A, v1B) ? [v1A, v1B] : [v1B, v1A];
  const [copySt, copyBody] = await memberAsk(env.conn, "PUT", "/admin/api/vault/vaults?copy=1", vWinner);
  assert.equal(copySt, 200, JSON.stringify(copyBody));
  assert.equal(copyBody.vault.name, vWinner.name);

  // 3) Concurrent PUT /vault/items at version 1: exactly one wins (200) and the other gets 409 vault_conflict.
  const item1Id = "i_01HZZZZZZZZZZZZZZZZZZZZR01";
  const makeItem = (vaultId: string, id: string, version: number, name: string): Item => signed({
    v: 1 as const,
    ws: WS,
    vault: vaultId,
    id,
    version,
    epoch: 0,
    ct: encryptWith(env.vaultKey, Buffer.from(JSON.stringify({ kind: "token", name, fields: { value: `v-${version}-${name}` }, domains: [], notes: "" })), itemContext(WS, vaultId, id, version, 0), fill(50 + version, 12)),
    listing: { name, kind: "token" as const, modes: ["env" as const], hosts: [], env: "RACE_TOK" },
    at: env.now + 10 + version,
  }, TAG.item, env.aliceSigner);

  assert.equal((await memberAsk(env.conn, "PUT", "/admin/api/vault/items", makeItem(VAULT1, item1Id, 0, "Shared Name")))[0], 200);
  const i1A = makeItem(VAULT1, item1Id, 1, "Shared Name A");
  const i1B = makeItem(VAULT1, item1Id, 1, "Shared Name B");
  const [irA, irB] = await Promise.all([
    memberAsk(env.conn, "PUT", "/admin/api/vault/items", i1A),
    memberAsk(env.conn, "PUT", "/admin/api/vault/items", i1B),
  ]);
  assert.deepEqual([irA[0], irB[0]].sort(), [200, 409], `concurrent item version=1 must yield one 200 and one 409: ${JSON.stringify([irA, irB])}`);
  const [iWinner] = itemSupersedes(i1A, i1B) ? [i1A, i1B] : [i1B, i1A];
  assert.equal((await memberAsk(env.conn, "PUT", "/admin/api/vault/items?copy=1", iWinner))[0], 200);

  // 4) secret_use by exact item ID vs duplicate listing name, plus Unicode name handling.
  const dupA = makeItem(VAULT1, "i_01HZZZZZZZZZZZZZZZZZZZZD01", 0, "Shared Alias Key");
  const dupB = makeItem(VAULT1, "i_01HZZZZZZZZZZZZZZZZZZZZD02", 0, "Shared Alias Key");
  const unicodeItem = makeItem(VAULT1, "i_01HZZZZZZZZZZZZZZZZZZZZN01", 0, "🔑 生产密钥 — 東京 (café)");
  assert.equal((await memberAsk(env.conn, "PUT", "/admin/api/vault/items", dupA))[0], 200);
  assert.equal((await memberAsk(env.conn, "PUT", "/admin/api/vault/items", dupB))[0], 200);
  assert.equal((await memberAsk(env.conn, "PUT", "/admin/api/vault/items", unicodeItem))[0], 200);

  // Addressing by exact item ID selects the specific item even when two items share a listing name.
  const exactRes = await tool(env.door, "t1", "secret_use", { item: "i_01HZZZZZZZZZZZZZZZZZZZZD02", mode: "env", reason: "select second alias by id" });
  assert.equal(exactRes.error, false, exactRes.text);
  const exactReqId = extractReqId(exactRes.text);

  // Unicode item name works end-to-end in secret_list, secret_use, and GET /vault/requests.
  const listUnicode = await tool(env.door, "t1", "secret_list", {});
  assert.equal(listUnicode.error, false, listUnicode.text);
  assert.match(listUnicode.text, /🔑 生产密钥 — 東京 \(café\)/);
  const useUnicode = await tool(env.door, "t1", "secret_use", { item: "🔑 生产密钥 — 東京 (café)", mode: "env", reason: "测试 Unicode 密钥请求" });
  assert.equal(useUnicode.error, false, useUnicode.text);
  const unicodeReqId = extractReqId(useUnicode.text);

  // 5) NUL-suffixed & duplicate JSON-key ambiguity guards in live DB read through Admin API.
  const db = new DatabaseSync(join(env.data, "stillfail.db"));
  // (the running station writes the same database: wait for its lock, as every connection to it does)
  db.exec("PRAGMA busy_timeout = 5000;");
  try {
    // Pending request where NUL-suffixed key says "v_other" but actual "vault" key is VAULT1 -> must remain visible to Alice.
    db.prepare("INSERT INTO vault_requests (ws, id, session, status, body) VALUES (?, ?, 's1', 'pending', ?)")
      .run(WS, "r_NULPENDING00000000000000", `{"ws":"${WS}","id":"r_NULPENDING00000000000000","session":"s1","vault\\u0000suffix":"v_other","vault":"${VAULT1}","item":"${item1Id}","mode":"env","reason":"nul pending","box":"","at":${env.now},"status":"pending"}`);
    // Granted use where NUL-suffixed key tries to spoof VAULT1 while actual "vault" is "v_other" -> must NOT leak into VAULT1 uses!
    db.prepare("INSERT INTO vault_requests (ws, id, session, status, body) VALUES (?, ?, 's1', 'granted', ?)")
      .run(WS, "r_NULUSELEAK00000000000000", `{"ws":"${WS}","id":"r_NULUSELEAK00000000000000","session":"s1","vault\\u0000suffix":"${VAULT1}","vault":"v_other","item":"spoofed-nul-item","mode":"env","reason":"spoof","box":"","at":${env.now},"status":"granted"}`);
    // Duplicate JSON keys (`vault-use-ambiguity`): last key wins per JSON.parse.
    db.prepare("INSERT INTO vault_requests (ws, id, session, status, body) VALUES (?, ?, 's1', 'granted', ?)")
      .run(WS, "r_DUPWIN000000000000000000", `{"ws":"${WS}","id":"r_DUPWIN000000000000000000","session":"s1","vault":"v_wrong","vault":"${VAULT1}","item":"dup-winner-item","mode":"env","reason":"dup win","box":"","at":${env.now + 5},"status":"granted"}`);
    db.prepare("INSERT INTO vault_requests (ws, id, session, status, body) VALUES (?, ?, 's1', 'granted', ?)")
      .run(WS, "r_DUPLEAK00000000000000000", `{"ws":"${WS}","id":"r_DUPLEAK00000000000000000","session":"s1","vault":"${VAULT1}","vault":"v_wrong","item":"dup-leaked-item","mode":"env","reason":"dup leak","box":"","at":${env.now + 6},"status":"granted"}`);
  } finally {
    db.close();
  }

  const [pendingSt, pendingBody] = await memberAsk(env.conn, "GET", "/admin/api/vault/requests");
  assert.equal(pendingSt, 200, JSON.stringify(pendingBody));
  const pendingIds = pendingBody.requests.map((r: any) => r.id);
  const exactPending = pendingBody.requests.find((r: any) => r.id === exactReqId);
  assert.equal(exactPending?.item, "i_01HZZZZZZZZZZZZZZZZZZZZD02", "exact item ID request must bind to second item");
  assert.ok(pendingIds.includes(unicodeReqId), "unicode request present");
  assert.ok(pendingIds.includes("r_NULPENDING00000000000000"), `NUL-suffixed vault key must not hide real pending request: ${JSON.stringify(pendingIds)}`);

  const [usesSt, usesBody] = await memberAsk(env.conn, "GET", `/admin/api/vault/uses?vault=${VAULT1}`);
  assert.equal(usesSt, 200, JSON.stringify(usesBody));
  const useItems = usesBody.uses.map((u: any) => u.item);
  assert.ok(useItems.includes("dup-winner-item"), `duplicate-key winner must be included in uses: ${JSON.stringify(useItems)}`);
  assert.ok(!useItems.includes("spoofed-nul-item"), `NUL-suffixed vault key must not leak use into ${VAULT1}: ${JSON.stringify(useItems)}`);
  assert.ok(!useItems.includes("dup-leaked-item"), `duplicate-key loser must not leak use into ${VAULT1}: ${JSON.stringify(useItems)}`);

  // 6) Atomic vault deletion: create VAULT2 with an item, delete VAULT2, verify items removed atomically and subsequent item writes refused (404).
  const v2 = makeVault(VAULT2, 0, "Disposable Vault");
  assert.equal((await memberAsk(env.conn, "PUT", "/admin/api/vault/vaults", v2))[0], 200);
  const v2Item = makeItem(VAULT2, "i_01HZZZZZZZZZZZZZZZZZZZZV2A", 0, "Temp Secret");
  assert.equal((await memberAsk(env.conn, "PUT", "/admin/api/vault/items", v2Item))[0], 200);

  const v2Deleted: Vault = signed({
    v: 1 as const,
    ws: WS,
    id: VAULT2,
    seq: 1,
    owner: "alice",
    name: "Disposable Vault",
    members: ["alice"],
    epoch: 1,
    keys: [],
    deleted: true as const,
    at: env.now + 20,
  }, TAG.vault, env.aliceSigner);
  const [delV2St, delV2Body] = await memberAsk(env.conn, "PUT", "/admin/api/vault/vaults", v2Deleted);
  assert.equal(delV2St, 200, JSON.stringify(delV2Body));
  assert.equal(delV2Body.vault.deleted, true);

  const [v2ItemsSt, v2ItemsBody] = await memberAsk(env.conn, "GET", `/admin/api/vault/items?vault=${VAULT2}`);
  assert.equal(v2ItemsSt, 200, JSON.stringify(v2ItemsBody));
  assert.deepEqual(v2ItemsBody.items, [], "vault deletion must atomically remove all its items");

  const v2NewItem = makeItem(VAULT2, "i_01HZZZZZZZZZZZZZZZZZZZZV2B", 0, "After Delete");
  const [postDelItemSt] = await memberAsk(env.conn, "PUT", "/admin/api/vault/items", v2NewItem);
  assert.equal(postDelItemSt, 404, "PUT /vault/items on deleted vault must be refused with 404");

  assert.doesNotMatch(env.launched.err(), /SQLITE_BUSY|database is locked|unknown op|no hub call/i);
  env.launched.tell({ op: "stop" });
  assert.equal(await env.launched.ended, 0, env.launched.err());
});

test("Vault SSH agent (`mode: ssh` Ed25519 + RSA) & file delivery (`mode: file` temp file cleanup + output redaction)", { skip: skipMesh }, async () => {
  const WS = "01HZZZZZZZZZZZZZZZZZZZZP05";
  const VAULT = "v_01HZZZZZZZZZZZZZZZZZZZZP05";
  const env = await setupLockedStation({ ws: WS, vaultId: VAULT, tag: "sshfile" });

  // Helper script run inside `secret_run` to speak RFC draft-miller-ssh-agent over `$SSH_AUTH_SOCK`.
  const sshProbe = join(env.work, "ssh-probe.mjs");
  writeFileSync(sshProbe, `
    import { createConnection } from "node:net";
    import { writeFileSync } from "node:fs";
    const sock = process.env.SSH_AUTH_SOCK;
    const out = process.argv[2];
    const flags = Number(process.argv[3] ?? "0");
    const u32 = (n) => Buffer.from([n >>> 24, (n >>> 16) & 255, (n >>> 8) & 255, n & 255]);
    const sshStr = (b) => Buffer.concat([u32(b.length), b]);
    const readStr = (b, at) => { const n = b.readUInt32BE(at); return [b.subarray(at + 4, at + 4 + n), at + 4 + n]; };
    const ask = (msg) => new Promise((resolve, reject) => {
      const s = createConnection(sock);
      let got = Buffer.alloc(0);
      s.on("data", (d) => {
        got = Buffer.concat([got, d]);
        if (got.length >= 4 && got.length >= 4 + got.readUInt32BE(0)) {
          s.end();
          resolve(got.subarray(4, 4 + got.readUInt32BE(0)));
        }
      });
      s.on("error", reject);
      s.write(Buffer.concat([u32(msg.length), msg]));
    });
    const ids = await ask(Buffer.from([11]));
    if (ids[0] !== 12 || ids.readUInt32BE(1) !== 1) throw new Error("bad identities: " + ids[0]);
    const [blob] = readStr(ids, 5);
    const payload = Buffer.from("verify-me-ssh-payload");
    const signed = await ask(Buffer.concat([Buffer.from([13]), sshStr(blob), sshStr(payload), u32(flags)]));
    if (signed[0] !== 14) throw new Error("bad sign response: " + signed[0]);
    const [sig] = readStr(signed, 1);
    const [alg, at] = readStr(sig, 0);
    const [sigBytes] = readStr(sig, at);
    writeFileSync(out, JSON.stringify({
      sock,
      hasSecretEnv: Boolean(process.env.STILLFAIL_SECRET),
      alg: alg.toString("utf8"),
      sigHex: sigBytes.toString("hex"),
    }));
  `);

  const runSshCase = async (label: string, itemId: string, pair: ReturnType<typeof generateKeyPairSync>, flags: number, expectedAlg: string, hashAlg: string | null) => {
    const pem = pair.privateKey.export({ format: "pem", type: "pkcs8" }) as string;
    const payload = { kind: "ssh_key" as const, name: label, fields: { private_key: pem }, domains: [], notes: label };
    const item: Item = signed({
      v: 1 as const,
      ws: WS,
      vault: VAULT,
      id: itemId,
      version: 0,
      epoch: 0,
      ct: encryptWith(env.vaultKey, Buffer.from(JSON.stringify(payload)), itemContext(WS, VAULT, itemId, 0, 0), fill(60 + flags, 12)),
      listing: { name: label, kind: "ssh_key" as const, modes: ["ssh" as const], hosts: [] },
      at: env.now,
    }, TAG.item, env.aliceSigner);
    assert.equal((await memberAsk(env.conn, "PUT", "/admin/api/vault/items", item))[0], 200);

    const useRes = await tool(env.door, "t1", "secret_use", { item: label, mode: "ssh", reason: `sign with ${label}` });
    assert.equal(useRes.error, false, useRes.text);
    const reqId = extractReqId(useRes.text);
    const [, reqs] = await memberAsk(env.conn, "GET", "/admin/api/vault/requests");
    const req = reqs.requests.find((x: any) => x.id === reqId);
    assert.ok(req);
    const grant: Grant = signed({
      v: 1 as const,
      ws: WS,
      request: reqId,
      vault: VAULT,
      item: itemId,
      mode: "ssh" as const,
      hosts: [],
      scope: "chat" as const,
      timeout: { kind: "fixed" as const, seconds: 3600 },
      exp: env.now + 3600,
      secret: seal(req.box, Buffer.from(JSON.stringify(payload)), grantContext(WS, reqId)),
      at: env.now,
    }, TAG.grant, env.aliceSigner);
    const [gSt, gBody] = await memberAsk(env.conn, "POST", "/admin/api/vault/grants", grant);
    assert.equal(gSt, 200, JSON.stringify(gBody));

    const outPath = join(env.work, `ssh-out-${itemId}.json`);
    const ran = await tool(env.door, "t1", "secret_run", {
      grant: reqId,
      command: `"${process.execPath}" "${sshProbe}" "${outPath}" ${flags}`,
    });
    assert.equal(ran.error, false, ran.text);
    const res = JSON.parse(readFileSync(outPath, "utf8"));
    assert.equal(res.hasSecretEnv, false, "SSH mode must not expose private key in STILLFAIL_SECRET");
    assert.equal(res.alg, expectedAlg);
    assert.ok(verifySignature(hashAlg, Buffer.from("verify-me-ssh-payload"), pair.publicKey, Buffer.from(res.sigHex, "hex")), `${label} signature must verify`);
    assert.equal(existsSync(res.sock), false, "temporary SSH_AUTH_SOCK must be cleaned up after secret_run exits");
  };

  await runSshCase("Deploy Ed25519", "i_01HZZZZZZZZZZZZZZZZZZZZS01", generateKeyPairSync("ed25519"), 0, "ssh-ed25519", null);
  await runSshCase("Deploy RSA-256", "i_01HZZZZZZZZZZZZZZZZZZZZS02", generateKeyPairSync("rsa", { modulusLength: 2048 }), 2, "rsa-sha2-256", "sha256");

  // File delivery mode (`kind: "file"`, `mode: "file"`): temp file written with filename, content redacted in stdout, temp file removed on exit.
  const fileSecretText = "apiVersion: v1\nsecret-token: kube-file-s3cr3t-554433\n";
  const fileId = "i_01HZZZZZZZZZZZZZZZZZZZZF01";
  const filePayload = {
    kind: "file" as const,
    name: "Staging Kubeconfig",
    fields: { content: Buffer.from(fileSecretText).toString("base64"), filename: "kubeconfig.yaml" },
    domains: [],
    notes: "staging cluster",
  };
  const fileItem: Item = signed({
    v: 1 as const,
    ws: WS,
    vault: VAULT,
    id: fileId,
    version: 0,
    epoch: 0,
    ct: encryptWith(env.vaultKey, Buffer.from(JSON.stringify(filePayload)), itemContext(WS, VAULT, fileId, 0, 0), fill(71, 12)),
    listing: { name: "Staging Kubeconfig", kind: "file" as const, modes: ["file" as const], hosts: [], env: "KUBECONFIG" },
    at: env.now,
  }, TAG.item, env.aliceSigner);
  assert.equal((await memberAsk(env.conn, "PUT", "/admin/api/vault/items", fileItem))[0], 200);

  const useFile = await tool(env.door, "t1", "secret_use", { item: "Staging Kubeconfig", mode: "file", reason: "inspect cluster" });
  assert.equal(useFile.error, false, useFile.text);
  const fileReqId = extractReqId(useFile.text);
  const [, reqsF] = await memberAsk(env.conn, "GET", "/admin/api/vault/requests");
  const reqF = reqsF.requests.find((x: any) => x.id === fileReqId);
  assert.ok(reqF);
  const fileGrant: Grant = signed({
    v: 1 as const,
    ws: WS,
    request: fileReqId,
    vault: VAULT,
    item: fileId,
    mode: "file" as const,
    hosts: [],
    scope: "chat" as const,
    timeout: { kind: "fixed" as const, seconds: 3600 },
    exp: env.now + 3600,
    secret: seal(reqF.box, Buffer.from(JSON.stringify(filePayload)), grantContext(WS, fileReqId)),
    at: env.now,
  }, TAG.grant, env.aliceSigner);
  const [fgSt, fgBody] = await memberAsk(env.conn, "POST", "/admin/api/vault/grants", fileGrant);
  assert.equal(fgSt, 200, JSON.stringify(fgBody));

  const pathRecord = join(env.work, "file-path.txt");
  const runFile = await tool(env.door, "t1", "secret_run", {
    grant: fileReqId,
    command: `printf '%s' "$KUBECONFIG" > "${pathRecord}" && /bin/cat "$KUBECONFIG"`,
  });
  assert.equal(runFile.error, false, runFile.text);
  const tempFilePath = readFileSync(pathRecord, "utf8");
  assert.match(tempFilePath, /kubeconfig\.yaml$/, `temp file must preserve safe filename: ${tempFilePath}`);
  assert.equal(existsSync(tempFilePath), false, "temporary secret file must be removed after secret_run exits");
  assert.ok(!runFile.text.includes("kube-file-s3cr3t-554433"), `file secret content must be redacted from secret_run output: ${runFile.text}`);

  assert.doesNotMatch(env.launched.err(), /SQLITE_BUSY|database is locked|unknown op|no hub call/i);
  env.launched.tell({ op: "stop" });
  assert.equal(await env.launched.ended, 0, env.launched.err());
});

test("Vault browser sign-in lifecycle: kind=browser save, grant, sign_in reuse & validation", { skip: skipMesh }, async () => {
  const WS = "01HZZZZZZZZZZZZZZZZZZZZP06";
  const VAULT = "v_01HZZZZZZZZZZZZZZZZZZZZP06";
  const env = await setupLockedStation({ ws: WS, vaultId: VAULT, tag: "browser" });

  // 1) Store two browser sign-in items: one for github.com (granted immediately), one for linear.app (listed, not yet granted).
  const ghId = "i_01HZZZZZZZZZZZZZZZZZZZZB01";
  const linId = "i_01HZZZZZZZZZZZZZZZZZZZZB02";
  const ghPayload = {
    kind: "browser" as const,
    name: "GitHub Web Session",
    fields: { cookies: JSON.stringify([{ name: "user_session", value: "gh-cookie-s3cr3t", domain: ".github.com", path: "/" }]) },
    domains: ["github.com"],
    notes: "GitHub cookies",
  };
  const linPayload = {
    kind: "browser" as const,
    name: "Linear Web Session",
    fields: { cookies: JSON.stringify([{ name: "lin_session", value: "lin-cookie-s3cr3t", domain: ".linear.app", path: "/" }]) },
    domains: ["linear.app"],
    notes: "Linear cookies",
  };

  const makeBrowserItem = (id: string, payload: typeof ghPayload, host: string, nonce: number): Item => signed({
    v: 1 as const,
    ws: WS,
    vault: VAULT,
    id,
    version: 0,
    epoch: 0,
    ct: encryptWith(env.vaultKey, Buffer.from(JSON.stringify(payload)), itemContext(WS, VAULT, id, 0, 0), fill(nonce, 12)),
    listing: { name: payload.name, about: payload.notes, kind: "browser" as const, modes: ["browser" as const], hosts: [host] },
    at: env.now,
  }, TAG.item, env.aliceSigner);

  assert.equal((await memberAsk(env.conn, "PUT", "/admin/api/vault/items", makeBrowserItem(ghId, ghPayload, "github.com", 81)))[0], 200);
  assert.equal((await memberAsk(env.conn, "PUT", "/admin/api/vault/items", makeBrowserItem(linId, linPayload, "linear.app", 82)))[0], 200);

  // 2) `sign_in` for listed site `linear.app` automatically raises a vault `secret_use` request for the stored sign-in.
  const signLin = await tool(env.door, "t1", "sign_in", { site: "https://www.linear.app/team", reason: "check sprint issues" });
  assert.equal(signLin.error, false, signLin.text);
  const linReqId = extractReqId(signLin.text);
  assert.match(signLin.text, /Linear Web Session/);

  // 3) Grant `github.com` browser sign-in via `secret_use` + `POST /admin/api/vault/grants`.
  const useGh = await tool(env.door, "t1", "secret_use", { item: "GitHub Web Session", mode: "browser", reason: "review PR" });
  assert.equal(useGh.error, false, useGh.text);
  const ghReqId = extractReqId(useGh.text);
  const [, reqs] = await memberAsk(env.conn, "GET", "/admin/api/vault/requests");
  const ghReq = reqs.requests.find((x: any) => x.id === ghReqId);
  assert.ok(ghReq);
  assert.ok(reqs.requests.some((x: any) => x.id === linReqId), "sign_in-created vault request must appear in pending requests");

  const ghGrant: Grant = signed({
    v: 1 as const,
    ws: WS,
    request: ghReqId,
    vault: VAULT,
    item: ghId,
    mode: "browser" as const,
    hosts: ["github.com"],
    scope: "chat" as const,
    timeout: { kind: "fixed" as const, seconds: 3600 },
    exp: env.now + 3600,
    secret: seal(ghReq.box, Buffer.from(JSON.stringify(ghPayload)), grantContext(WS, ghReqId)),
    at: env.now,
  }, TAG.grant, env.aliceSigner);
  const [ghGrantSt, ghGrantBody] = await memberAsk(env.conn, "POST", "/admin/api/vault/grants", ghGrant);
  assert.equal(ghGrantSt, 200, JSON.stringify(ghGrantBody));

  // 4) Subsequent `sign_in` for `https://www.github.com/pulls` sees the already-held browser grant and does NOT open a new request.
  const signGh = await tool(env.door, "t1", "sign_in", { site: "https://www.github.com/pulls", reason: "check PRs" });
  assert.equal(signGh.error, false, signGh.text);
  assert.match(signGh.text, /again: true/);

  // 5) Validation: invalid site name and unlisted site with no open browser tab are both refused cleanly.
  const badSite = await tool(env.door, "t1", "sign_in", { site: "localhost", reason: "invalid" });
  assert.equal(badSite.error, true, badSite.text);
  const noTab = await tool(env.door, "t1", "sign_in", { site: "unlisted.example.test", reason: "no tab open" });
  assert.equal(noTab.error, true, noTab.text);
  assert.match(noTab.text, /no tab on unlisted\.example\.test/i);

  assert.doesNotMatch(env.launched.err(), /SQLITE_BUSY|database is locked|unknown op|no hub call/i);
  env.launched.tell({ op: "stop" });
  assert.equal(await env.launched.ended, 0, env.launched.err());
});
