// Live MoonBit station parity tests for Vault Admin API & MCP tools, Devices/Rigs/Logins, and cold-session
// wake via `hub.notify` (`hub_bridge` -> `hub.command`). All tests run against the real `stillfail-reader run`
// binary with no Node on its PATH, `STILLFAIL_LOCAL_ADMIN=1`, `/mcp`, and real loopback iroh mesh.
import assert from "node:assert/strict";
import { type ChildProcess, spawn, spawnSync } from "node:child_process";
import { createPublicKey, generateKeyPairSync, randomBytes, sign as nodeSign } from "node:crypto";
import { createSocket } from "node:dgram";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { request } from "node:http";
import { createServer, type Server } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { DatabaseSync } from "node:sqlite";
import { after, test } from "node:test";
import { type Entry, entryHash, signedBytes as lockBytes } from "../../shared/lock.ts";
import { loadMesh, type Connection, type Stream as MeshStream } from "../src/mesh/native.ts";
import { Reader } from "../src/mesh/wire.ts";
import { mbReaderBinary } from "../src/read/mb-reader.ts";
import { Store } from "../src/store/store.ts";
import {
  type BoxCert, type Deny, type Grant, type Item, type Sig, type Vault, TAG, encryptWith, grantContext, itemContext, keyContext, newBoxPair, seal, signedBytes,
} from "../src/vault/crypto.ts";
import { GrantKey } from "./fake-control-plane.ts";

const binary = mbReaderBinary();
const runner = process.env.STILLFAIL_RUNNER ?? "";
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
const skipRunner = skipMesh
  || (runner === "" || !existsSync(runner) ? "no stillfail-runner (run under scripts/native.ts run runner)" : false)
  || (!existsSync("/usr/bin/curl") ? "no /usr/bin/curl for the fake runtime" : false);

const dirs: string[] = [];
// (short: Unix sockets on macOS are capped at 104 bytes)
const fresh = (what: string) => {
  const dir = mkdtempSync(join(process.platform === "darwin" ? "/tmp" : tmpdir(), `sfv-${what}-`));
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
    rmSync(d, { recursive: true, force: true });
  }
});

const TOKEN = "vault-devices-parity-door";

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

async function uiAsk(port: number, op: string, args: unknown[] = []): Promise<{ answer?: any; error?: any; kind?: string }> {
  const got = await http(port, "/ui-ask/", { body: JSON.stringify({ op, args }), headers: { authorization: `Bearer ${TOKEN}` } });
  return JSON.parse(got.body);
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

test("Vault Admin API: snapshot object shapes, lock_devices plain object, and optimistic concurrency (#7525 regression)", { skip: skipMesh }, async () => {
  const WS = "01HZZZZZZZZZZZZZZZZZZZZZZZ";
  const VAULT = "v_01HZZZZZZZZZZZZZZZZZZZZZZZ";
  const ITEM = "i_01HZZZZZZZZZZZZZZZZZZZZZZZ";

  const data = fresh("vapi");
  const app = fresh("app");
  writeFileSync(join(app, "BUILD"), "9500\n");
  const id = stationId(data);
  const grant = new GrantKey();
  const meshPort = await freeUdpPort();

  const client = await addon!.bind({ secretKey: randomBytes(32), alpns: [Buffer.from("client/1")], relayUrls: [], discovery: false, bindAddr: "127.0.0.1:0" });
  cleanups.push(() => client.close());

  const aliceSigner = ed();
  const aliceBox = newBoxPair();
  const body = {
    owner: "alice",
    origins: ["https://app.still.fail"],
    rp_id: "app.still.fail",
    cloud_keys: { keys: [grant.jwk] },
    members: [{ sub: "alice", email: "alice@x.com", role: "owner" }],
    devices: [{ id: client.id(), sub: "alice", kind: "app", label: "alice-app", sign_key: aliceSigner.id }],
    passkeys: [],
    stations: [{ key: id, name: "here" }],
    gateways: [],
  };
  const e = { v: 1, ws: WS, seq: 0, prev: null, at: 1000, kind: "genesis", body } as Omit<Entry, "sig">;
  const genesisEntry: Entry = {
    ...e,
    sig: { key: aliceSigner.id, alg: "Ed25519" as const, sig: aliceSigner.sign(lockBytes(entryHash(e as Entry))) },
  };

  mkdirSync(join(data, "mesh"), { recursive: true });
  writeFileSync(join(data, "mesh", "cloud.json"), JSON.stringify({
    origin: "http://127.0.0.1:9",
    station: id,
    workspace: WS,
    workspace_name: "Team",
    name: "here",
    relay_url: "",
    relay_urls: [],
    grant_keys: { keys: [grant.jwk] },
    peers: [],
    revocations: [],
  }));
  writeFileSync(join(data, "mesh", "lock.json"), JSON.stringify({ entries: [genesisEntry] }));

  const a = await launch(data, app, { STILLFAIL_LOCAL_ADMIN: "1", STILLFAIL_MESH_BIND_ADDR: `127.0.0.1:${meshPort}` });
  await a.next("ready", (m) => m.ready === true);
  const door = (await a.next("mcp", (m) => m.serving === "mcp")).port as number;

  // Verify the station's vault.lock exposes `devices` as a plain object (not a `$map` bridge).
  const lockAns = await uiAsk(door, "vault.lock", [WS, { sub: "alice", email: "alice@x.com" }]);
  assert.equal(typeof lockAns.answer, "object", JSON.stringify(lockAns));
  assert.ok(lockAns.answer && typeof lockAns.answer.devices === "object" && !Array.isArray(lockAns.answer.devices), JSON.stringify(lockAns.answer));
  assert.equal(lockAns.answer.devices.$map, undefined, "MoonBit vault.lock uses plain object for devices");
  assert.ok(lockAns.answer.devices[client.id()], `device ${client.id()} present in lock.devices`);

  const now = Math.floor(Date.now() / 1000);
  const cred = grant.credential(
    { typ: "stillfail-member+jwt" },
    { iss: "stillfail-cloud", sub: "alice", email: "alice@x.com", name: "Alice", ws: WS, role: "owner", device: client.id(), sid: "s-vapi", iat: now, exp: now + 3600 },
  );
  const conn = await given("connected to station over mesh", () => client.connect({ id, ips: [`127.0.0.1:${meshPort}`] }, Buffer.from("stillfail/admin/1")));
  const hello = await member(conn, cred);
  assert.equal(hello.ok, true, JSON.stringify(hello));

  // 1) Box certificate write & read (verifies `lock_devices` plain-object handling and `boxSnapshot` `{ value, body }`).
  const cert1: BoxCert = signed({ v: 1 as const, ws: WS, device: client.id(), box: aliceBox.pub, at: 2000 }, TAG.box, aliceSigner);
  const [boxPutStatus, boxPutBody] = await memberAsk(conn, "PUT", "/admin/api/vault/boxes", cert1);
  assert.equal(boxPutStatus, 200, JSON.stringify(boxPutBody));
  assert.equal(boxPutBody.box.device, client.id());

  const [boxGetStatus, boxGetBody] = await memberAsk(conn, "GET", "/admin/api/vault/boxes");
  assert.equal(boxGetStatus, 200, JSON.stringify(boxGetBody));
  assert.deepEqual(boxGetBody.boxes.map((b: any) => b.device), [client.id()], "GET /vault/boxes must return devices from plain-object lock");

  const boxSnap = (await uiAsk(door, "vaults.boxSnapshot", [WS, client.id()])).answer;
  assert.equal(Array.isArray(boxSnap), false, `boxSnapshot must be an object, got ${JSON.stringify(boxSnap)}`);
  assert.deepEqual(Object.keys(boxSnap).sort(), ["body", "value"]);
  assert.equal(typeof boxSnap.body, "string");
  assert.equal(boxSnap.value.device, client.id());

  // Newer box certificate overwrites held box snapshot; older does not overwrite.
  const cert2: BoxCert = signed({ v: 1 as const, ws: WS, device: client.id(), box: aliceBox.pub, at: 2001 }, TAG.box, aliceSigner);
  const [boxPut2Status, boxPut2Body] = await memberAsk(conn, "PUT", "/admin/api/vault/boxes", cert2);
  assert.equal(boxPut2Status, 200, JSON.stringify(boxPut2Body));
  assert.equal(boxPut2Body.box.at, 2001);
  const [boxOldStatus, boxOldBody] = await memberAsk(conn, "PUT", "/admin/api/vault/boxes", cert1);
  assert.equal(boxOldStatus, 200, JSON.stringify(boxOldBody));
  assert.equal(boxOldBody.box.at, 2001, "older box cert must not overwrite newer one");

  // 2) Vault write, read, latest, snapshot shape, and optimistic concurrency conflict.
  const vaultKey = fill(4);
  const makeVault = (seq: number, name: string): Vault => signed({
    v: 1 as const,
    ws: WS,
    id: VAULT,
    seq,
    owner: "alice",
    name,
    members: ["alice"],
    epoch: 0,
    keys: [{ cert: cert2, wrapped: seal(aliceBox.pub, vaultKey, keyContext(WS, VAULT, 0)) }],
    at: 2000 + seq,
  }, TAG.vault, aliceSigner);

  const v0 = makeVault(0, "Personal");
  const [v0Status, v0Body] = await memberAsk(conn, "PUT", "/admin/api/vault/vaults", v0);
  assert.equal(v0Status, 200, JSON.stringify(v0Body));
  assert.equal(v0Body.vault.seq, 0);

  const [vListStatus, vListBody] = await memberAsk(conn, "GET", "/admin/api/vault/vaults");
  assert.equal(vListStatus, 200, JSON.stringify(vListBody));
  assert.deepEqual(vListBody.vaults.map((v: any) => [v.id, v.seq]), [[VAULT, 0]]);

  const vaultSnap = (await uiAsk(door, "vaults.vaultSnapshot", [WS, VAULT])).answer;
  assert.equal(Array.isArray(vaultSnap), false, `vaultSnapshot must be an object, got ${JSON.stringify(vaultSnap)}`);
  assert.deepEqual(Object.keys(vaultSnap).sort(), ["body", "value"]);
  assert.equal(typeof vaultSnap.body, "string");
  assert.equal(vaultSnap.value.id, VAULT);
  assert.equal(vaultSnap.value.seq, 0);

  // Version conflict on vault (re-putting seq 0 must return 409 vault_conflict and not overwrite).
  const [vConflictStatus, vConflictBody] = await memberAsk(conn, "PUT", "/admin/api/vault/vaults", makeVault(0, "Stale"));
  assert.equal(vConflictStatus, 409, JSON.stringify(vConflictBody));
  assert.equal(vConflictBody.code, "vault_conflict");
  assert.equal(vConflictBody.vault.name, "Personal");

  // Next seq (seq 1) succeeds over held vaultSnapshot.
  const v1 = makeVault(1, "Personal Renamed");
  const [v1Status, v1Body] = await memberAsk(conn, "PUT", "/admin/api/vault/vaults", v1);
  assert.equal(v1Status, 200, JSON.stringify(v1Body));
  assert.equal(v1Body.vault.seq, 1);

  const [vLatestStatus, vLatestBody] = await memberAsk(conn, "POST", "/admin/api/vault/vaults/latest", { held: [v0] });
  assert.equal(vLatestStatus, 200, JSON.stringify(vLatestBody));
  assert.equal(vLatestBody.vaults.length, 1);
  assert.equal(vLatestBody.vaults[0].seq, 1);

  // 3) Item write, read, snapshot shape, and optimistic concurrency conflict (direct #7525 regression).
  const makeItem = (version: number, name: string): Item => signed({
    v: 1 as const,
    ws: WS,
    vault: VAULT,
    id: ITEM,
    version,
    epoch: 0,
    ct: encryptWith(vaultKey, new TextEncoder().encode(JSON.stringify({ kind: "token", name, fields: { value: `tok-${version}` }, domains: [], notes: "" })), itemContext(WS, VAULT, ITEM, version, 0), fill(5 + version, 12)),
    listing: { name, kind: "token" as const, modes: ["env" as const], hosts: [], env: "MY_TOK" },
    at: 2100 + version,
  }, TAG.item, aliceSigner);

  const i0 = makeItem(0, "GitHub");
  const [i0Status, i0Body] = await memberAsk(conn, "PUT", "/admin/api/vault/items", i0);
  assert.equal(i0Status, 200, `PUT /vault/items must succeed (regression #7525): ${JSON.stringify(i0Body)}`);
  assert.equal(i0Body.item.version, 0);

  const [iListStatus, iListBody] = await memberAsk(conn, "GET", `/admin/api/vault/items?vault=${VAULT}`);
  assert.equal(iListStatus, 200, JSON.stringify(iListBody));
  assert.deepEqual(iListBody.items.map((x: any) => [x.id, x.version]), [[ITEM, 0]]);

  const itemSnap = (await uiAsk(door, "vaults.itemSnapshot", [WS, VAULT, ITEM])).answer;
  assert.equal(Array.isArray(itemSnap), false, `itemSnapshot must be an object, got ${JSON.stringify(itemSnap)}`);
  assert.deepEqual(Object.keys(itemSnap).sort(), ["body", "value"]);
  assert.equal(typeof itemSnap.body, "string");
  assert.equal(itemSnap.value.id, ITEM);
  assert.equal(itemSnap.value.version, 0);

  // Version conflict on item (re-putting version 0 must return 409 vault_conflict and not overwrite).
  const [iConflictStatus, iConflictBody] = await memberAsk(conn, "PUT", "/admin/api/vault/items", makeItem(0, "StaleItem"));
  assert.equal(iConflictStatus, 409, JSON.stringify(iConflictBody));
  assert.equal(iConflictBody.code, "vault_conflict");
  assert.equal(iConflictBody.item.listing.name, "GitHub");

  // Next version (version 1) succeeds over held itemSnapshot.
  const i1 = makeItem(1, "GitHub Updated");
  const [i1Status, i1Body] = await memberAsk(conn, "PUT", "/admin/api/vault/items", i1);
  assert.equal(i1Status, 200, JSON.stringify(i1Body));
  assert.equal(i1Body.item.version, 1);

  assert.doesNotMatch(a.err(), /SQLITE_BUSY|database is locked|unknown op|no hub call/i);
  a.tell({ op: "stop" });
  assert.equal(await a.ended, 0, a.err());
});

test("Vault MCP full lifecycle: secret_save, secret_list, secret_use, secret_run (redacted), secret_describe, secret_cancel, secret_delete", { skip: skipMesh }, async () => {
  const WS = "01HZZZZZZZZZZZZZZZZZZZZZ02";
  const VAULT = "v_01HZZZZZZZZZZZZZZZZZZZZZ02";
  const data = fresh("vlife");
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
  const vaultKey = fill(9);
  const genesisBody = {
    owner: "alice",
    origins: ["https://app.still.fail"],
    rp_id: "app.still.fail",
    cloud_keys: { keys: [grant.jwk] },
    members: [{ sub: "alice", email: "alice@x.com", role: "owner" }],
    devices: [{ id: client.id(), sub: "alice", kind: "app", label: "alice-app", sign_key: aliceSigner.id }],
    passkeys: [],
    stations: [{ key: id, name: "here" }],
    gateways: [],
  };
  const ge = { v: 1, ws: WS, seq: 0, prev: null, at: 1000, kind: "genesis", body: genesisBody } as Omit<Entry, "sig">;
  const genesisEntry: Entry = {
    ...ge,
    sig: { key: aliceSigner.id, alg: "Ed25519" as const, sig: aliceSigner.sign(lockBytes(entryHash(ge as Entry))) },
  };

  mkdirSync(join(data, "mesh"), { recursive: true });
  writeFileSync(join(data, "mesh", "cloud.json"), JSON.stringify({
    origin: "http://127.0.0.1:9",
    station: id,
    workspace: WS,
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
  s.insertSession({ key: "s1", connect: "chat", runtime: "claude", profile: "cc", workspace: work, token: "t1", createdBy: "alice@x.com", ws: WS, createdAt: Date.now(), lastActiveAt: Date.now() });
  const thread = s.openThread("chat", "CHAT", "1795000000.001000", "vault lifecycle", "alice@x.com").id;
  s.joinThread(thread, "s1", "chat");
  s.close();

  const a = await launch(data, app, { STILLFAIL_LOCAL_ADMIN: "1", STILLFAIL_MESH_BIND_ADDR: `127.0.0.1:${meshPort}` });
  await a.next("ready", (m) => m.ready === true);
  const door = (await a.next("mcp", (m) => m.serving === "mcp")).port as number;

  const now = Math.floor(Date.now() / 1000);
  const cred = grant.credential(
    { typ: "stillfail-member+jwt" },
    { iss: "stillfail-cloud", sub: "alice", email: "alice@x.com", name: "Alice", ws: WS, role: "owner", device: client.id(), sid: "s-life", iat: now, exp: now + 3600 },
  );
  const conn = await given("connected to station over mesh", () => client.connect({ id, ips: [`127.0.0.1:${meshPort}`] }, Buffer.from("stillfail/admin/1")));
  assert.equal((await member(conn, cred)).ok, true);

  // Initialize Alice's box cert and encrypted vault via Admin API.
  const cert: BoxCert = signed({ v: 1 as const, ws: WS, device: client.id(), box: aliceBox.pub, at: now }, TAG.box, aliceSigner);
  assert.equal((await memberAsk(conn, "PUT", "/admin/api/vault/boxes", cert))[0], 200);
  const vault: Vault = signed({
    v: 1 as const,
    ws: WS,
    id: VAULT,
    seq: 0,
    owner: "alice",
    name: "Personal",
    members: ["alice"],
    epoch: 0,
    keys: [{ cert, wrapped: seal(aliceBox.pub, vaultKey, keyContext(WS, VAULT, 0)) }],
    at: now,
  }, TAG.vault, aliceSigner);
  assert.equal((await memberAsk(conn, "PUT", "/admin/api/vault/vaults", vault))[0], 200);

  // 1) secret_save -> card posted -> approve via Admin API (PUT /vault/items + POST /vault/saves with immediate grant) -> secret_list shows name, about & active grant.
  const SECRET_VALUE = "s3cr3t-acme-token-99887766";
  const saveRes = await tool(door, "t1", "secret_save", {
    kind: "token",
    name: "Acme Deploy Key",
    about: "Used for staging deploys",
    modes: ["env"],
    env: "ACME_DEPLOY_TOKEN",
    reason: "save staging deploy token",
  });
  assert.equal(saveRes.error, false, saveRes.text);
  const saveReqId = extractReqId(saveRes.text);

  const [reqs1Status, reqs1Body] = await memberAsk(conn, "GET", "/admin/api/vault/requests");
  assert.equal(reqs1Status, 200, JSON.stringify(reqs1Body));
  const saveReq = reqs1Body.requests.find((r: any) => r.id === saveReqId);
  assert.ok(saveReq, `pending save request ${saveReqId} in ${JSON.stringify(reqs1Body)}`);

  const plainPayload = (name: string, about: string) => ({
    kind: "token" as const,
    name,
    fields: { value: SECRET_VALUE },
    domains: [],
    notes: about,
  });
  const makeItem = (version: number, name: string, about: string, deleted = false): Item => signed({
    v: 1 as const,
    ws: WS,
    vault: VAULT,
    id: saveReq.item,
    version,
    epoch: 0,
    ct: deleted ? "" : encryptWith(vaultKey, Buffer.from(JSON.stringify(plainPayload(name, about))), itemContext(WS, VAULT, saveReq.item, version, 0), fill(20 + version, 12)),
    ...(deleted ? { deleted: true as const } : { listing: { name, about, kind: "token" as const, modes: ["env" as const], hosts: [], env: "ACME_DEPLOY_TOKEN" } }),
    at: now + version,
  }, TAG.item, aliceSigner);

  assert.equal((await memberAsk(conn, "PUT", "/admin/api/vault/items", makeItem(0, "Acme Deploy Key", "Used for staging deploys")))[0], 200);
  const saveGrant: Grant = signed({
    v: 1 as const,
    ws: WS,
    request: saveReqId,
    vault: VAULT,
    item: saveReq.item,
    mode: "env" as const,
    hosts: [],
    scope: "chat" as const,
    exp: now + 3600,
    secret: seal(saveReq.box, Buffer.from(JSON.stringify(plainPayload("Acme Deploy Key", "Used for staging deploys"))), grantContext(WS, saveReqId)),
    at: now,
  }, TAG.grant, aliceSigner);
  const [savedStatus, savedBody] = await memberAsk(conn, "POST", "/admin/api/vault/saves", {
    request: saveReqId,
    vault: VAULT,
    grant: saveGrant,
  });
  assert.equal(savedStatus, 200, JSON.stringify(savedBody));
  assert.equal(savedBody.ok, true);

  const listAfterSave = await tool(door, "t1", "secret_list", {});
  assert.equal(listAfterSave.error, false, listAfterSave.text);
  assert.match(listAfterSave.text, /Acme Deploy Key/);
  assert.match(listAfterSave.text, /Used for staging deploys/);
  assert.match(listAfterSave.text, new RegExp(saveReqId), "approved save should grant immediate access");

  // 2) secret_use -> approve via Admin API -> secret_run injects real env var and redacts output.
  const useRes = await tool(door, "t1", "secret_use", {
    item: "Acme Deploy Key",
    mode: "env",
    reason: "run deploy verification script",
  });
  assert.equal(useRes.error, false, useRes.text);
  const useReqId = extractReqId(useRes.text);

  const [reqs2Status, reqs2Body] = await memberAsk(conn, "GET", "/admin/api/vault/requests");
  assert.equal(reqs2Status, 200, JSON.stringify(reqs2Body));
  const useReq = reqs2Body.requests.find((r: any) => r.id === useReqId);
  assert.ok(useReq, `pending use request ${useReqId}`);

  const useGrant: Grant = signed({
    v: 1 as const,
    ws: WS,
    request: useReqId,
    vault: VAULT,
    item: saveReq.item,
    mode: "env" as const,
    hosts: [],
    scope: "chat" as const,
    timeout: { kind: "fixed" as const, seconds: 3600 },
    exp: now + 3600,
    secret: seal(useReq.box, Buffer.from(JSON.stringify(plainPayload("Acme Deploy Key", "Used for staging deploys"))), grantContext(WS, useReqId)),
    at: now,
  }, TAG.grant, aliceSigner);
  const [grantStatus, grantBody] = await memberAsk(conn, "POST", "/admin/api/vault/grants", useGrant);
  assert.equal(grantStatus, 200, JSON.stringify(grantBody));

  const outFile = join(work, "injected-value.txt");
  const runRes = await tool(door, "t1", "secret_run", {
    grant: useReqId,
    command: `printf '%s' "$ACME_DEPLOY_TOKEN" > "${outFile}" && printf 'stdout-echo:%s\\n' "$ACME_DEPLOY_TOKEN"`,
  });
  assert.equal(runRes.error, false, runRes.text);
  assert.equal(readFileSync(outFile, "utf8"), SECRET_VALUE, "subprocess must receive real secret value in env");
  assert.ok(!runRes.text.includes(SECRET_VALUE), `secret_run output must redact secret value, got: ${runRes.text}`);
  assert.match(runRes.text, /stdout-echo:/);
  // A cwd given whole runs there, as paths.ts `joinPath` keeps it, never joined under the session's workspace.
  const absDir = fresh("cwd");
  const absRun = await tool(door, "t1", "secret_run", { grant: useReqId, cwd: absDir, command: "pwd -P" });
  assert.equal(absRun.error, false, absRun.text);
  assert.ok(absRun.text.includes(realpathSync(absDir)), `secret_run must run in ${absDir}, got: ${absRun.text}`);

  // 3) secret_describe -> approve via Admin API -> secret_list reflects updated name & about.
  const descRes = await tool(door, "t1", "secret_describe", {
    item: "Acme Deploy Key",
    name: "Acme Prod Deploy Key",
    about: "Production release token",
    reason: "clarify production scope",
  });
  assert.equal(descRes.error, false, descRes.text);
  const descReqId = extractReqId(descRes.text);

  assert.equal((await memberAsk(conn, "PUT", "/admin/api/vault/items", makeItem(1, "Acme Prod Deploy Key", "Production release token")))[0], 200);
  const [descApproveStatus, descApproveBody] = await memberAsk(conn, "POST", "/admin/api/vault/described", {
    request: descReqId,
  });
  assert.equal(descApproveStatus, 200, JSON.stringify(descApproveBody));

  const listAfterDesc = await tool(door, "t1", "secret_list", {});
  assert.equal(listAfterDesc.error, false, listAfterDesc.text);
  assert.match(listAfterDesc.text, /Acme Prod Deploy Key/);
  assert.match(listAfterDesc.text, /Production release token/);

  // 4) secret_cancel -> withdraws pending request, closes card, removes from pending list.
  const cancelTargetRes = await tool(door, "t1", "secret_use", {
    item: "Acme Prod Deploy Key",
    mode: "env",
    reason: "temporary request to cancel",
  });
  assert.equal(cancelTargetRes.error, false, cancelTargetRes.text);
  const cancelReqId = extractReqId(cancelTargetRes.text);

  const [beforeCancelStatus, beforeCancelBody] = await memberAsk(conn, "GET", "/admin/api/vault/requests");
  assert.equal(beforeCancelStatus, 200);
  assert.ok(beforeCancelBody.requests.some((r: any) => r.id === cancelReqId), "pending request present before cancel");

  const cancelRes = await tool(door, "t1", "secret_cancel", { request: cancelReqId });
  assert.equal(cancelRes.error, false, cancelRes.text);

  const [afterCancelStatus, afterCancelBody] = await memberAsk(conn, "GET", "/admin/api/vault/requests");
  assert.equal(afterCancelStatus, 200);
  assert.ok(!afterCancelBody.requests.some((r: any) => r.id === cancelReqId), "cancelled request must be removed from pending list");

  const db = new DatabaseSync(join(data, "stillfail.db"), { readOnly: true });
  try {
    await given("cancelled card closed in closed_cards", () => {
      const row = db.prepare("SELECT COUNT(*) AS n FROM closed_cards WHERE thread = ?").get(thread) as { n: number };
      return row.n >= 1;
    });
  } finally {
    db.close();
  }

  // 5) secret_delete -> approve via Admin API -> item marked deleted, removed from secret_list, and new secret_use refused.
  const delRes = await tool(door, "t1", "secret_delete", {
    item: "Acme Prod Deploy Key",
    reason: "token rotated and decommissioned",
  });
  assert.equal(delRes.error, false, delRes.text);
  const delReqId = extractReqId(delRes.text);

  assert.equal((await memberAsk(conn, "PUT", "/admin/api/vault/items", makeItem(2, "", "", true)))[0], 200);
  const [delApproveStatus, delApproveBody] = await memberAsk(conn, "POST", "/admin/api/vault/removed", {
    request: delReqId,
  });
  assert.equal(delApproveStatus, 200, JSON.stringify(delApproveBody));

  const listAfterDel = await tool(door, "t1", "secret_list", {});
  assert.equal(listAfterDel.error, false, listAfterDel.text);
  assert.doesNotMatch(listAfterDel.text, /Acme Prod Deploy Key/);

  const [itemsAfterDelStatus, itemsAfterDelBody] = await memberAsk(conn, "GET", `/admin/api/vault/items?vault=${VAULT}`);
  assert.equal(itemsAfterDelStatus, 200, JSON.stringify(itemsAfterDelBody));
  const deletedItem = itemsAfterDelBody.items.find((x: any) => x.id === saveReq.item);
  assert.equal(deletedItem?.deleted, true, JSON.stringify(itemsAfterDelBody));

  const useAfterDel = await tool(door, "t1", "secret_use", {
    item: "Acme Prod Deploy Key",
    mode: "env",
    reason: "must fail after deletion",
  });
  assert.equal(useAfterDel.error, true, `secret_use must fail after item deletion, got: ${useAfterDel.text}`);

  assert.doesNotMatch(a.err(), /SQLITE_BUSY|database is locked|unknown op|no hub call/i);
  a.tell({ op: "stop" });
  assert.equal(await a.ended, 0, a.err());
});

test("Devices, Rigs & Logins live round-trip: device_list, device_use/done, station_use deny, and login start/list/cancel", { skip: skipBase }, async () => {
  const WS = "w-dev-rig-login";
  const data = fresh("drl");
  const app = fresh("app");
  const work = fresh("work");
  const bin = fresh("bin");
  writeFileSync(join(app, "BUILD"), "9500\n");

  // Stand-in login CLI script (pure /bin/sh, no Node): prints a device-code prompt and waits.
  const loginScript = join(bin, "fake-cli-login");
  writeFileSync(loginScript, `#!/bin/sh
printf 'To sign in, open https://auth.example.test/device and enter code: ABCD-1234\\n'
/bin/sleep 30
`, { mode: 0o755 });
  chmodSync(loginScript, 0o755);

  // Local TCP device echo server.
  const echo = createServer((sock) => sock.on("data", (d) => sock.write(Buffer.concat([Buffer.from("echo:"), d]))));
  await new Promise<void>((r) => echo.listen(0, "127.0.0.1", () => r()));
  cleanups.push(() => echo.close());
  const echoPort = (echo.address() as any).port as number;

  const id = stationId(data);
  const rigId = "ab".repeat(32);
  mkdirSync(join(data, "mesh"), { recursive: true });
  writeFileSync(join(data, "mesh", "cloud.json"), JSON.stringify({
    origin: "http://127.0.0.1:9",
    station: id,
    workspace: WS,
    workspace_name: "Team",
    name: "here",
    relay_url: "",
    relay_urls: [],
    grant_keys: {},
    peers: [],
    revocations: [],
    rigs: [{ id: rigId, name: "build-rig", owner: "local", owner_email: "owner@x.com", owner_name: "Owner" }],
  }));

  const s = openStore(data);
  s.insertSession({ key: "s1", connect: "chat", runtime: "claude", profile: "cc", workspace: work, token: "t1", createdBy: "owner@x.com", ws: WS, createdAt: Date.now(), lastActiveAt: Date.now() });
  const thread = s.openThread("chat", "CHAT", "1795000000.002000", "devices and logins", "owner@x.com").id;
  s.joinThread(thread, "s1", "chat");
  s.close();

  const a = await launch(data, app, { STILLFAIL_LOCAL_ADMIN: "1" });
  await a.next("ready", (m) => m.ready === true);
  const door = (await a.next("mcp", (m) => m.serving === "mcp")).port as number;

  // 1) Add local TCP device via Admin API -> device_list -> device_use -> device_use(done: true).
  const addDev = await http(door, "/admin-api/devices", {
    body: JSON.stringify({ name: "bench-cam", kind: "tcp", target: `127.0.0.1:${echoPort}` }),
  });
  assert.equal(addDev.status, 200, addDev.body);
  const devObj = JSON.parse(addDev.body).device;
  assert.equal(devObj.name, "bench-cam");

  const listed = await tool(door, "t1", "device_list", {});
  assert.equal(listed.error, false, listed.text);
  assert.match(listed.text, /bench-cam/);
  assert.match(listed.text, /tcp/i);

  const used = await tool(door, "t1", "device_use", { device: "bench-cam", reason: "read camera telemetry" });
  assert.equal(used.error, false, used.text);
  assert.match(used.text, /127\.0\.0\.1:\d+/, `device_use should open a loopback forward: ${used.text}`);

  const handedBack = await tool(door, "t1", "device_use", { device: "bench-cam", done: true });
  assert.equal(handedBack.error, false, handedBack.text);

  // 2) station_use -> card posted -> denied via Admin API -> card closed & restated.
  const rigAsk = await tool(door, "t1", "station_use", { station: "build-rig", reason: "run linux build" });
  assert.equal(rigAsk.error, false, rigAsk.text);

  const db = new DatabaseSync(join(data, "stillfail.db"), { readOnly: true });
  try {
    const reqRow = await given("rig request saved", () => db.prepare("SELECT id, status, body FROM rig_requests WHERE session = 's1'").get() as { id: string; status: string; body: string } | undefined);
    assert.equal(reqRow.status, "pending");

    const denyRes = await http(door, `/admin-api/rigs/requests/${reqRow.id}/decide`, { body: JSON.stringify({ allow: false }) });
    assert.equal(denyRes.status, 200, denyRes.body);
    assert.equal(JSON.parse(denyRes.body).request.status, "denied");

    await given("rig card restated as denied", () => {
      const edit = db.prepare("SELECT card FROM entries WHERE thread = ? AND kind = 'edit' AND card IS NOT NULL ORDER BY n DESC LIMIT 1").get(thread) as { card: string } | undefined;
      return edit ? JSON.parse(edit.card)?.rig?.outcome?.status === "denied" : false;
    });
  } finally {
    db.close();
  }

  // 3) login MCP tool -> redacted output for agent, full details in GET /admin-api/machine-logins, cancelled via DELETE.
  const loginStart = await tool(door, "t1", "login", { command: loginScript });
  assert.equal(loginStart.error, false, loginStart.text);
  assert.ok(!loginStart.text.includes("https://auth.example.test/device"), `login tool must redact URL: ${loginStart.text}`);
  assert.ok(!loginStart.text.includes("ABCD-1234"), `login tool must redact device code: ${loginStart.text}`);

  const loginsList = await given("machine-logins lists active login", async () => {
    const r = await http(door, "/admin-api/machine-logins");
    if (r.status !== 200) return null;
    const body = JSON.parse(r.body);
    return body.logins?.find((l: any) => l.code === "ABCD-1234") ?? null;
  });
  assert.equal(loginsList.url, "https://auth.example.test/device");
  assert.equal(loginsList.code, "ABCD-1234");

  const loginCancel = await http(door, `/admin-api/machine-logins/${encodeURIComponent(loginsList.id)}`, { method: "DELETE" });
  assert.equal(loginCancel.status, 200, loginCancel.body);

  await given("cancelled login no longer active", async () => {
    const r = await http(door, "/admin-api/machine-logins");
    if (r.status !== 200) return false;
    const found = JSON.parse(r.body).logins?.find((l: any) => l.id === loginsList.id);
    return !found || found.status !== "waiting";
  });

  assert.doesNotMatch(a.err(), /SQLITE_BUSY|database is locked|unknown op|no hub call/i);
  a.tell({ op: "stop" });
  assert.equal(await a.ended, 0, a.err());
});

test("Cold-session wake via hub.notify (hub_bridge -> hub.command) on vault and rig card decisions", { skip: skipRunner }, async () => {
  const WS = "w-cold-notify";
  const data = fresh("cold");
  const app = fresh("app");
  const bin = fresh("bin");
  const out = fresh("out");
  const workVault = fresh("wv");
  const workRig = fresh("wr");
  writeFileSync(join(app, "BUILD"), "9500\n");

  // Fake `claude` (pure /bin/sh + /usr/bin/curl, no Node): records received prompt and posts all_done.
  const fakeClaude = `#!/bin/sh
sid=""; cfg=""
while [ $# -gt 0 ]; do
  case "$1" in
    --session-id|--resume) sid="$2"; shift ;;
    --mcp-config) cfg="$2"; shift ;;
  esac
  shift
done
url=$(printf '%s' "$cfg" | /usr/bin/sed -n 's/.*"url":"\\([^"]*\\)".*/\\1/p')
say() { printf '%s\\n' "$1"; }
n=0
while IFS= read -r line; do
  case "$line" in *'"type":"user"'*) ;; *) continue ;; esac
  n=$((n+1))
  printf '%s\\n' "$line" > "$FAKE_OUT/prompt-$sid-$n.json"
  say '{"type":"system","subtype":"init","session_id":"'"$sid"'","model":"default","tools":[],"mcp_servers":[]}'
  say '{"type":"system","subtype":"status","status":"requesting","session_id":"'"$sid"'"}'
  /usr/bin/curl -s -X POST "$url" -H 'content-type: application/json' -H "authorization: Bearer $STILLFAIL_MCP_TOKEN" \\
    -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"chat_state","arguments":{"kind":"all_done","done":"received notification"}}}' > "$FAKE_OUT/state-$sid-$n.json"
  say '{"type":"result","subtype":"success","is_error":false,"duration_ms":1,"num_turns":1,"session_id":"'"$sid"'","result":"ok"}'
done
`;
  writeFileSync(join(bin, "claude"), fakeClaude, { mode: 0o755 });
  chmodSync(join(bin, "claude"), 0o755);

  const id = stationId(data);
  const rigId = "cd".repeat(32);
  const grant = new GrantKey();
  const meshPort = await freeUdpPort();

  const client = await addon!.bind({ secretKey: randomBytes(32), alpns: [Buffer.from("client/1")], relayUrls: [], discovery: false, bindAddr: "127.0.0.1:0" });
  cleanups.push(() => client.close());

  const aliceSigner = ed();
  const genesisBody = {
    owner: "alice",
    origins: ["https://app.still.fail"],
    rp_id: "app.still.fail",
    cloud_keys: { keys: [grant.jwk] },
    members: [{ sub: "alice", email: "alice@x.com", role: "owner" }],
    devices: [{ id: client.id(), sub: "alice", kind: "app", label: "alice-app", sign_key: aliceSigner.id }],
    passkeys: [],
    stations: [{ key: id, name: "here" }, { key: rigId, name: "cold-rig" }],
    gateways: [],
  };
  const ge = { v: 1, ws: WS, seq: 0, prev: null, at: 1000, kind: "genesis", body: genesisBody } as Omit<Entry, "sig">;
  const genesisEntry: Entry = {
    ...ge,
    sig: { key: aliceSigner.id, alg: "Ed25519" as const, sig: aliceSigner.sign(lockBytes(entryHash(ge as Entry))) },
  };

  mkdirSync(join(data, "mesh"), { recursive: true });
  writeFileSync(join(data, "mesh", "cloud.json"), JSON.stringify({
    origin: "http://127.0.0.1:9",
    station: id,
    workspace: WS,
    workspace_name: "Team",
    name: "here",
    relay_url: "",
    relay_urls: [],
    grant_keys: { keys: [grant.jwk] },
    peers: [],
    revocations: [],
    rigs: [{ id: rigId, name: "cold-rig", owner: "local", owner_email: "alice@x.com", owner_name: "Alice" }],
  }));
  writeFileSync(join(data, "mesh", "lock.json"), JSON.stringify({ entries: [genesisEntry] }));

  // Two cold sessions pre-inserted in SQLite (neither has an in-memory actor when the station starts).
  const s = openStore(data);
  s.insertSession({ key: "s-vault", connect: "chat", runtime: "claude", profile: "cc", workspace: workVault, token: "t-vault", createdBy: "alice@x.com", ws: WS, createdAt: Date.now(), lastActiveAt: Date.now() });
  const tVault = s.openThread("chat", "CHAT", "1795000000.003000", "cold vault", "alice@x.com").id;
  s.joinThread(tVault, "s-vault", "chat");

  s.insertSession({ key: "s-rig", connect: "chat", runtime: "claude", profile: "cc", workspace: workRig, token: "t-rig", createdBy: "alice@x.com", ws: WS, createdAt: Date.now(), lastActiveAt: Date.now() });
  const tRig = s.openThread("chat", "CHAT", "1795000000.004000", "cold rig", "alice@x.com").id;
  s.joinThread(tRig, "s-rig", "chat");
  s.close();

  const a = await launch(data, app, {
    PATH: bin,
    HOME: data,
    STILLFAIL_RUNNER: runner,
    STILLFAIL_AGENT_NICE: "0",
    FAKE_OUT: out,
    STILLFAIL_LOCAL_ADMIN: "1",
    STILLFAIL_MESH_BIND_ADDR: `127.0.0.1:${meshPort}`,
  });
  await a.next("ready", (m) => m.ready === true);
  const door = (await a.next("mcp", (m) => m.serving === "mcp")).port as number;

  const now = Math.floor(Date.now() / 1000);
  const cred = grant.credential(
    { typ: "stillfail-member+jwt" },
    { iss: "stillfail-cloud", sub: "alice", email: "alice@x.com", name: "Alice", ws: WS, role: "owner", device: client.id(), sid: "s-cold", iat: now, exp: now + 3600 },
  );
  const conn = await given("connected to station over mesh", () => client.connect({ id, ips: [`127.0.0.1:${meshPort}`] }, Buffer.from("stillfail/admin/1")));
  assert.equal((await member(conn, cred)).ok, true);

  // 1) Cold session `s-vault`: secret_save -> denied via Admin API -> hub.notify wakes cold session & launches fake claude.
  const saveRes = await tool(door, "t-vault", "secret_save", {
    kind: "token",
    name: "Cold Token",
    about: "cold wake test",
    modes: ["env"],
    reason: "test cold wake on vault decision",
  });
  assert.equal(saveRes.error, false, saveRes.text);
  const saveReqId = extractReqId(saveRes.text);

  const deny: Deny = signed({ v: 1 as const, ws: WS, request: saveReqId, at: now }, TAG.deny, aliceSigner);
  const [denyVaultStatus, denyVaultBody] = await memberAsk(conn, "POST", "/admin/api/vault/denials", deny);
  assert.equal(denyVaultStatus, 200, JSON.stringify(denyVaultBody));

  const vaultPrompt = await given("cold session s-vault woken by vault hub.notify", () => {
    const files = readdirSync(out).filter((f) => f.startsWith("prompt-"));
    for (const f of files) {
      const content = readFileSync(join(out, f), "utf8");
      if (content.includes("Cold Token") || content.includes(saveReqId)) return content;
    }
    return null;
  }, 25_000);
  assert.match(vaultPrompt, /Cold Token|declined|denied|拒绝/i);

  // 2) Cold session `s-rig`: station_use -> denied via Admin API -> hub.notify wakes cold session & launches fake claude.
  const rigRes = await tool(door, "t-rig", "station_use", { station: "cold-rig", reason: "test cold wake on rig decision" });
  assert.equal(rigRes.error, false, rigRes.text);

  const db = new DatabaseSync(join(data, "stillfail.db"), { readOnly: true });
  let rigReqId = "";
  try {
    const row = await given("rig request saved for s-rig", () => db.prepare("SELECT id FROM rig_requests WHERE session = 's-rig'").get() as { id: string } | undefined);
    rigReqId = row.id;
  } finally {
    db.close();
  }
  const rigDeny = await http(door, `/admin-api/rigs/requests/${rigReqId}/decide`, { body: JSON.stringify({ allow: false }) });
  assert.equal(rigDeny.status, 200, rigDeny.body);

  const rigPrompt = await given("cold session s-rig woken by rig hub.notify", () => {
    const files = readdirSync(out).filter((f) => f.startsWith("prompt-"));
    for (const f of files) {
      const content = readFileSync(join(out, f), "utf8");
      if (content.includes("cold-rig") || content.includes(rigReqId)) return content;
    }
    return null;
  }, 25_000);
  assert.match(rigPrompt, /cold-rig|declined|denied|拒绝/i);

  assert.doesNotMatch(a.err(), /SQLITE_BUSY|database is locked|unknown op|no hub call/i);
  a.tell({ op: "stop" });
  assert.equal(await a.ended, 0, a.err());
});
