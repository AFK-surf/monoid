// Faults and edges of the vault as the MoonBit station (`stillfail-reader run`, no Node on its PATH) holds them, the
// TypeScript's unit tests (vault-once-handover, vault-keeper, vault-box-version-race, vault-personal-lock,
// vault-restore-startup, vault-signin) asked of the real program:
// 1. A one-use grant raced by two `secret_run`s, and by the station before and after a handover: one run at most; spent
//    it stays spent over a cold restart; its value never in what is said.
// 2. A locked vault's fixed grant runs out at its approval's deadline, an idle one is kept on by its uses past it and
//    runs out once unused; neither ending touches another grant; a locked one-use grant raced runs once.
// 3. A device's box certificate never goes back to an older one, raced, replayed after a restart, or signed by a key
//    not in the lock.
// 4. On startup: expired grants let go in batches without holding up the station, live and idle-renewed ones usable
//    at once, an archived chat's grants and waiting sign-in not taken up again, and no session uses another's grant.
import assert from "node:assert/strict";
import { type ChildProcess, spawn, spawnSync } from "node:child_process";
import { createPublicKey, generateKeyPairSync, randomBytes, sign as nodeSign } from "node:crypto";
import { createSocket } from "node:dgram";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
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
import { mbStationBinary } from "./mb-harness.ts";
import { Store } from "../src/store/store.ts";
import {
  type BoxCert, type Grant, type Item, type Sig, type Vault, TAG, encryptWith, grantContext, itemContext, keyContext, newBoxPair, seal, signedBytes,
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

const dirs: string[] = [];
// (short: Unix sockets on macOS are capped at 104 bytes)
const fresh = (what: string) => {
  const dir = mkdtempSync(join(process.platform === "darwin" ? "/tmp" : tmpdir(), `sfvc-${what}-`));
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

const noNode = (more: Record<string, string> = {}) => ({
  PATH: fresh("path"),
  HOME: process.env.HOME ?? tmpdir(),
  TMPDIR: tmpdir(),
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
    env: noNode({ STILLFAIL_LOCAL_ADMIN: "1", ...more }),
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

/** Until the wall clock passes `secs` (seconds since the epoch): the station's expiries are the wall's. */
const past = (secs: number) => given(`the wall clock past ${secs}`, () => Date.now() / 1000 > secs, 15_000);

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
  if (r.status !== 200) return { text: `HTTP ${r.status}: ${r.body}`, error: true };
  const parsed = JSON.parse(r.body);
  if (parsed.error !== undefined) return { text: JSON.stringify(parsed.error), error: true };
  return { text: parsed.result.content.map((c: any) => c.text).join("\n"), error: parsed.result.isError === true };
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

/** The station's database as another connection: waiting for its lock, as every connection to it does. */
function withDb<T>(data: string, f: (db: DatabaseSync) => T, readOnly = false): T {
  const db = new DatabaseSync(join(data, "stillfail.db"), { readOnly });
  db.exec("PRAGMA busy_timeout = 5000;");
  try {
    return f(db);
  } finally {
    db.close();
  }
}

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

const stop = async (l: Launched) => {
  l.tell({ op: "stop" });
  assert.equal(await l.ended, 0, l.err());
};

// ── the plain library (no security mode): its grants are written down and taken up again ──

type PlainSession = { key: string; token: string; archived?: boolean };

/** A station of the plain library with these sessions, started once so that its vault's tables are there. */
async function plainStation(tag: string, ws: string, sessions: PlainSession[]) {
  const data = fresh(tag);
  const app = fresh("app");
  const work = fresh("work");
  writeFileSync(join(app, "BUILD"), "9500\n");
  const s = openStore(data);
  for (const [i, x] of sessions.entries()) {
    s.insertSession({ key: x.key, connect: "chat", runtime: "claude", profile: "cc", workspace: work, token: x.token, createdBy: "owner@local", ws, createdAt: Date.now(), lastActiveAt: Date.now() });
    const thread = s.openThread("chat", "CHAT", `17950000${String(i).padStart(2, "0")}.00${i}000`, `${tag}-${x.key}`, "owner@local").id;
    s.joinThread(thread, x.key, "chat");
    if (x.archived) s.setArchived(x.key, true, "owner@local");
  }
  s.close();
  const first = await launch(data, app);
  await first.next("ready", (m) => m.ready === true);
  await stop(first);
  return { data, app, work };
}

const plainRequest = (ws: string, id: string, item: string, session: string, mode: string, at: number) =>
  ({ id, ws, vault: "plain", item, session, chat: `CHAT/${session}`, owner: "owner@local", mode, reason: id, box: "", at, status: "granted" });

/** Writes a plain item and its grants down as a station before this one did. */
function seedPlain(data: string, ws: string, item: { id: string; name: string; value: string; env: string; kind?: string; modes?: string[]; hosts?: string[]; fields?: Record<string, string> },
  grants: { id: string; session: string; scope: "once" | "hour" | "chat"; exp: number; at: number; uses?: number; until?: number; timeout?: { kind: "idle" | "fixed"; seconds: number }; mode?: string; hosts?: string[] }[]) {
  const now = Math.floor(Date.now() / 1000);
  withDb(data, (db) => {
    const body = {
      ws, id: item.id, owner: "owner@local", version: 0, kind: item.kind ?? "token", name: item.name,
      fields: item.fields ?? { value: item.value }, notes: "",
      listing: { name: item.name, kind: item.kind ?? "token", modes: item.modes ?? ["env"], hosts: item.hosts ?? [], env: item.env },
      at: now - 10,
    };
    db.prepare("INSERT INTO vault_plain (ws, id, owner, version, body) VALUES (?, ?, ?, ?, ?)").run(ws, item.id, "owner@local", 0, JSON.stringify(body));
    db.exec("BEGIN IMMEDIATE");
    for (const g of grants) {
      const mode = g.mode ?? "env";
      const req = plainRequest(ws, g.id, item.id, g.session, mode, g.at);
      const gr = { v: 1, ws, request: g.id, vault: "plain", item: item.id, mode, hosts: g.hosts ?? [], scope: g.scope, exp: g.exp, ...(g.timeout ? { timeout: g.timeout } : {}), at: g.at };
      db.prepare("INSERT INTO vault_grants (ws, id, session, body) VALUES (?, ?, ?, ?)")
        .run(ws, g.id, g.session, JSON.stringify({ request: req, grant: gr, uses: g.uses ?? 0, ...(g.until !== undefined ? { until: g.until } : {}) }));
    }
    db.exec("COMMIT");
  });
}

const grantRow = (data: string, ws: string, id: string) =>
  withDb(data, (db) => {
    const row = db.prepare("SELECT body FROM vault_grants WHERE ws = ? AND id = ?").get(ws, id) as { body: string } | undefined;
    return row === undefined ? undefined : JSON.parse(row.body) as { uses: number; until?: number };
  }, true);

const lines = (path: string) => (existsSync(path) ? readFileSync(path, "utf8").split("\n").filter((l) => l !== "") : []);

test("a one-use plain grant raced by two secret_runs runs once; spent, it stays spent over a cold restart; its value never said", { skip: skipBase }, async () => {
  const WS = "ws-once-race";
  const VALUE = "once-race-s3cr3t-9081";
  const env = await plainStation("oncerace", WS, [{ key: "s1", token: "t1" }]);
  const now = Math.floor(Date.now() / 1000);
  const ids = ["r_01HZZZZZZZZZZZZZZZZZZZOR01", "r_01HZZZZZZZZZZZZZZZZZZZOR02", "r_01HZZZZZZZZZZZZZZZZZZZOR03"];
  seedPlain(env.data, WS, { id: "ip-race", name: "Race Token", value: VALUE, env: "RACE_TOK" },
    ids.map((id) => ({ id, session: "s1", scope: "once" as const, exp: now + 3600, at: now - 5 })));

  const a = await launch(env.data, env.app);
  await a.next("ready", (m) => m.ready === true);
  const door = (await a.next("mcp", (m) => m.serving === "mcp")).port as number;

  for (const id of ids) {
    const marker = join(env.work, `${id}.ran`);
    // Each run leaves a line and takes a moment, so that the other is asked while it runs as well as before it.
    const run = (n: number) => tool(door, "t1", "secret_run", {
      grant: id,
      command: `printf '%s\\n' "${n}:$RACE_TOK" >> "${marker}"; sleep 0.2; printf 'ran-${n}:%s' "$RACE_TOK"`,
    });
    const answers = await Promise.all([run(1), run(2), run(3)]);
    const ran = answers.filter((x) => !x.error);
    assert.equal(ran.length, 1, `exactly one of three racing runs of once grant ${id}: ${JSON.stringify(answers)}`);
    for (const refused of answers.filter((x) => x.error)) assert.match(refused.text, /for one use and is used|already used/, refused.text);
    for (const x of answers) assert.ok(!x.text.includes(VALUE), `the value is never said: ${x.text}`);
    assert.match(ran[0]!.text, /ran-\d:/);
    const left = lines(marker);
    assert.equal(left.length, 1, `the command ran once: ${JSON.stringify(left)}`);
    assert.ok(left[0]!.endsWith(`:${VALUE}`), "the one run had the value in its environment");
    assert.equal(grantRow(env.data, WS, id)?.uses, 1, "its record says it was used once");
  }
  await stop(a);

  // A cold restart takes the spent grants up as spent: none runs again.
  const b = await launch(env.data, env.app);
  await b.next("ready", (m) => m.ready === true);
  const bDoor = (await b.next("mcp", (m) => m.serving === "mcp")).port as number;
  for (const id of ids) {
    const again = await tool(bDoor, "t1", "secret_run", { grant: id, command: `printf again >> "${join(env.work, `${id}.ran`)}"` });
    assert.equal(again.error, true, `spent once grant ${id} refused after a restart: ${again.text}`);
    assert.match(again.text, /for one use and is used/);
    assert.ok(!again.text.includes(VALUE));
    assert.equal(lines(join(env.work, `${id}.ran`)).length, 1, "nothing ran after the restart");
  }
  assert.doesNotMatch(b.err(), new RegExp(VALUE), "the value is never logged");
  assert.doesNotMatch(a.err(), new RegExp(VALUE), "the value is never logged");
  await stop(b);
});

test("a one-use plain grant during a handover: run by the station before as it hands over, the one after (which read it down unspent) does not run it again; an unspent one runs once after it", { skip: skipBase, timeout: 120_000 }, async () => {
  const WS = "ws-once-handover";
  const VALUE = "once-handover-s3cr3t-5512";
  const env = await plainStation("onceho", WS, [{ key: "s1", token: "t1" }]);
  const now = Math.floor(Date.now() / 1000);
  const RACED = "r_01HZZZZZZZZZZZZZZZZZZZOH01";
  const UNSPENT = "r_01HZZZZZZZZZZZZZZZZZZZOH02";
  seedPlain(env.data, WS, { id: "ip-ho", name: "Handover Token", value: VALUE, env: "HO_TOK" }, [
    { id: RACED, session: "s1", scope: "once", exp: now + 3600, at: now - 5 },
    { id: UNSPENT, session: "s1", scope: "once", exp: now + 3600, at: now - 5 },
  ]);

  const a = await launch(env.data, env.app);
  await a.next("ready", (m) => m.ready === true);
  const aDoor = (await a.next("a mcp", (m) => m.serving === "mcp")).port as number;

  // The next station is up beside it on the same database, having read the grant down as unspent, before the one
  // before spends it: it serves only once that one has handed over.
  const b = await launch(env.data, env.app);
  await b.next("b ready", (m) => m.ready === true);

  const raced = join(env.work, "raced.ran");
  const run = (door: number, who: string, id: string, marker: string, more = "") => tool(door, "t1", "secret_run", {
    grant: id,
    command: `printf '%s\\n' "${who}:$HO_TOK" >> "${marker}";${more} printf 'ran-${who}'`,
  });
  // The station before runs it and is told to hand over while the command still runs.
  const onA = run(aDoor, "a", RACED, raced, " sleep 0.5;");
  await given("the station before running the command", () => lines(raced).length === 1);
  a.tell({ op: "handover" });
  const carry = await a.next("carry", (m) => m.carry !== undefined);
  assert.equal(await a.ended, 0, a.err());
  b.tell({ op: "carried", carried: carry.carry });
  const bDoor = (await b.next("b mcp", (m) => m.serving === "mcp")).port as number;
  const ranA = await onA;
  assert.equal(ranA.error, false, `the station before ran it: ${ranA.text}`);
  assert.ok(!ranA.text.includes(VALUE), ranA.text);
  const onB = await run(bDoor, "b", RACED, raced);
  assert.equal(onB.error, true, `the station after does not run it again: ${onB.text}`);
  assert.match(onB.text, /for one use and is used/);
  assert.ok(!onB.text.includes(VALUE), onB.text);
  assert.deepEqual(lines(raced), [`a:${VALUE}`], "the command ran once across both stations");
  assert.equal(grantRow(env.data, WS, RACED)?.uses, 1);

  // Neither station spent the other one: the station after runs it once, then no more.
  const unspent = join(env.work, "unspent.ran");
  const first = await run(bDoor, "b1", UNSPENT, unspent);
  assert.equal(first.error, false, first.text);
  const second = await run(bDoor, "b2", UNSPENT, unspent);
  assert.equal(second.error, true, `an unspent once grant runs once after the handover: ${second.text}`);
  assert.deepEqual(lines(unspent), [`b1:${VALUE}`]);
  const third = await run(bDoor, "b3", RACED, raced);
  assert.equal(third.error, true, `the raced grant stays spent after the handover: ${third.text}`);
  assert.equal(lines(raced).length, 1);
  await stop(b);
});

// ── a locked vault (security mode): grants signed by a member's device, held only in memory ──

async function lockedStation(opts: { ws: string; vaultId: string; tag: string; meshPort?: number }) {
  const data = fresh(opts.tag);
  const app = fresh("app");
  const work = fresh("work");
  writeFileSync(join(app, "BUILD"), "9500\n");
  const id = stationId(data);
  const grant = new GrantKey();
  const meshPort = opts.meshPort ?? await freeUdpPort();

  const client = await addon!.bind({ secretKey: randomBytes(32), alpns: [Buffer.from("client/1")], relayUrls: [], discovery: false, bindAddr: "127.0.0.1:0" });
  cleanups.push(() => client.close());

  const aliceSigner = ed();
  const aliceBox = newBoxPair();
  const vaultKey = fill(23);
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
  const ge = { v: 1, ws: opts.ws, seq: 0, prev: null, at: 1000, kind: "genesis", body: genesisBody } as Omit<Entry, "sig">;
  const genesisEntry: Entry = { ...ge, sig: { key: aliceSigner.id, alg: "Ed25519" as const, sig: aliceSigner.sign(lockBytes(entryHash(ge as Entry))) } };

  mkdirSync(join(data, "mesh"), { recursive: true });
  writeFileSync(join(data, "mesh", "cloud.json"), JSON.stringify({
    origin: "http://127.0.0.1:9", station: id, workspace: opts.ws, workspace_name: "Team", name: "here",
    relay_url: "", relay_urls: [], grant_keys: { keys: [grant.jwk] }, peers: [], revocations: [],
  }));
  writeFileSync(join(data, "mesh", "lock.json"), JSON.stringify({ entries: [genesisEntry] }));

  const s = openStore(data);
  for (const [key, token, ts] of [["s1", "t1", "1795000000.011000"], ["s2", "t2", "1795000000.012000"]] as const) {
    s.insertSession({ key, connect: "chat", runtime: "claude", profile: "cc", workspace: work, token, createdBy: "alice@x.com", ws: opts.ws, createdAt: Date.now(), lastActiveAt: Date.now() });
    s.joinThread(s.openThread("chat", "CHAT", ts, `${opts.tag}-${key}`, "alice@x.com").id, key, "chat");
  }
  s.close();

  const start = async () => {
    const launched = await launch(data, app, { STILLFAIL_MESH_BIND_ADDR: `127.0.0.1:${meshPort}` });
    await launched.next("ready", (m) => m.ready === true);
    const door = (await launched.next("mcp", (m) => m.serving === "mcp")).port as number;
    const now = Math.floor(Date.now() / 1000);
    const cred = grant.credential(
      { typ: "stillfail-member+jwt" },
      { iss: "stillfail-cloud", sub: "alice", email: "alice@x.com", name: "Alice", ws: opts.ws, role: "owner", device: client.id(), sid: `s-${opts.tag}`, iat: now, exp: now + 3600 },
    );
    const conn = await given("connected to station over mesh", () => client.connect({ id, ips: [`127.0.0.1:${meshPort}`] }, Buffer.from("stillfail/admin/1")));
    assert.equal((await member(conn, cred)).ok, true);
    return { launched, door, conn };
  };
  const first = await start();
  const now = Math.floor(Date.now() / 1000);
  const cert: BoxCert = signed({ v: 1 as const, ws: opts.ws, device: client.id(), box: aliceBox.pub, at: now }, TAG.box, aliceSigner);
  assert.equal((await memberAsk(first.conn, "PUT", "/admin/api/vault/boxes", cert))[0], 200);
  const vault: Vault = signed({
    v: 1 as const, ws: opts.ws, id: opts.vaultId, seq: 0, owner: "alice", name: "Personal", members: ["alice"], epoch: 0,
    keys: [{ cert, wrapped: seal(aliceBox.pub, vaultKey, keyContext(opts.ws, opts.vaultId, 0)) }], at: now,
  }, TAG.vault, aliceSigner);
  assert.equal((await memberAsk(first.conn, "PUT", "/admin/api/vault/vaults", vault))[0], 200);
  return { data, app, work, id, client, aliceSigner, aliceBox, vaultKey, cert, vault, start, ...first };
}

test("a locked vault: a fixed grant runs out at its deadline, an idle one is kept on by its uses past it and runs out unused; neither ending touches another grant; a raced one-use grant runs once", { skip: skipMesh, timeout: 120_000 }, async () => {
  const WS = "01HZZZZZZZZZZZZZZZZZZZZT91";
  const VAULT = "v_01HZZZZZZZZZZZZZZZZZZZZT91";
  const ITEM = "i_01HZZZZZZZZZZZZZZZZZZZZT91";
  const VALUE = "timed-grants-s3cr3t-7731";
  const env = await lockedStation({ ws: WS, vaultId: VAULT, tag: "timed" });
  const at = Math.floor(Date.now() / 1000);
  const payload = { kind: "token" as const, name: "Timed Token", fields: { value: VALUE }, domains: [], notes: "" };
  const item: Item = signed({
    v: 1 as const, ws: WS, vault: VAULT, id: ITEM, version: 0, epoch: 0,
    ct: encryptWith(env.vaultKey, Buffer.from(JSON.stringify(payload)), itemContext(WS, VAULT, ITEM, 0, 0), fill(61, 12)),
    listing: { name: "Timed Token", about: "timed", kind: "token" as const, modes: ["env" as const], hosts: [], env: "TIMED_TOK" },
    at,
  }, TAG.item, env.aliceSigner);
  assert.equal((await memberAsk(env.conn, "PUT", "/admin/api/vault/items", item))[0], 200);

  const askAndGrant = async (token: string, scope: "once" | "hour" | "chat", timeout?: { kind: "idle" | "fixed"; seconds: number }) => {
    const r = await tool(env.door, token, "secret_use", { item: "Timed Token", mode: "env", reason: `${scope} ${timeout?.kind ?? ""}` });
    assert.equal(r.error, false, r.text);
    const reqId = extractReqId(r.text);
    const [, reqs] = await memberAsk(env.conn, "GET", "/admin/api/vault/requests");
    const req = reqs.requests.find((x: any) => x.id === reqId);
    assert.ok(req, `request ${reqId} waiting`);
    const now = Math.floor(Date.now() / 1000);
    const g: Grant = signed({
      v: 1 as const, ws: WS, request: reqId, vault: VAULT, item: ITEM, mode: "env" as const, hosts: [], scope,
      ...(timeout ? { timeout } : {}),
      exp: now + (timeout?.seconds ?? 3600),
      secret: seal(req.box, Buffer.from(JSON.stringify(payload)), grantContext(WS, reqId)),
      at: now,
    }, TAG.grant, env.aliceSigner);
    const [st, body] = await memberAsk(env.conn, "POST", "/admin/api/vault/grants", g);
    assert.equal(st, 200, JSON.stringify(body));
    return { id: reqId, exp: g.exp };
  };
  const run = (token: string, grant: string, what: string) => tool(env.door, token, "secret_run", { grant, command: `printf '${what}:%s' "$TIMED_TOK"` });
  const ran = async (token: string, grant: string, what: string) => {
    const r = await run(token, grant, what);
    assert.equal(r.error, false, `${what}: ${r.text}`);
    assert.ok(r.text.includes(`${what}:`) && !r.text.includes(VALUE), `${what} ran with its value hidden: ${r.text}`);
  };

  const chat = await askAndGrant("t1", "chat", { kind: "fixed", seconds: 3600 });
  const fixed = await askAndGrant("t1", "hour", { kind: "fixed", seconds: 3 });
  const idle = await askAndGrant("t1", "hour", { kind: "idle", seconds: 3 });

  // Another session never uses a grant it does not hold, and is told so without the value.
  const theirs = await run("t2", chat.id, "not-mine");
  assert.equal(theirs.error, true, `another session's grant refused: ${theirs.text}`);
  assert.match(theirs.text, /another session's/);
  assert.ok(!theirs.text.includes(VALUE));

  await ran("t1", fixed.id, "fixed-1");
  await ran("t1", idle.id, "idle-1");
  // Near the deadline both had at first, the idle one used again: kept on past it.
  await past(idle.exp - 1);
  await ran("t1", idle.id, "idle-2");
  await past(Math.max(fixed.exp, idle.exp) + 0.5);
  const fixedLate = await run("t1", fixed.id, "fixed-late");
  assert.equal(fixedLate.error, true, `a fixed grant runs out at its deadline whatever its uses: ${fixedLate.text}`);
  assert.match(fixedLate.text, /ran out|no such grant/i);
  assert.ok(!fixedLate.text.includes(VALUE));
  await ran("t1", idle.id, "idle-3");
  const lastUse = Date.now() / 1000;
  await ran("t1", chat.id, "chat-after-fixed");

  // Unused for longer than its timeout, the idle one runs out as well.
  await past(lastUse + 3 + 0.5);
  const idleLate = await run("t1", idle.id, "idle-late");
  assert.equal(idleLate.error, true, `an idle grant unused past its timeout runs out: ${idleLate.text}`);
  assert.match(idleLate.text, /ran out|no such grant/i);
  assert.ok(!idleLate.text.includes(VALUE));
  const fixedAgain = await run("t1", fixed.id, "fixed-again");
  assert.equal(fixedAgain.error, true, fixedAgain.text);

  // The grants that ended took no other with them.
  await ran("t1", chat.id, "chat-after-idle");

  // A locked one-use grant raced: one run.
  const once = await askAndGrant("t1", "once");
  const marker = join(env.work, "locked-once.ran");
  const answers = await Promise.all([1, 2, 3].map((n) => tool(env.door, "t1", "secret_run", {
    grant: once.id, command: `printf '%s\\n' "${n}" >> "${marker}"; sleep 0.2; printf 'once-${n}:%s' "$TIMED_TOK"`,
  })));
  assert.equal(answers.filter((x) => !x.error).length, 1, `a locked once grant raced runs once: ${JSON.stringify(answers)}`);
  assert.equal(lines(marker).length, 1);
  for (const x of answers) assert.ok(!x.text.includes(VALUE), x.text);
  await ran("t1", chat.id, "chat-after-once");

  assert.doesNotMatch(env.launched.err(), new RegExp(VALUE), "the value is never logged");
  await stop(env.launched);
});

test("a device's box certificate never goes back: racing older and newer, replayed after a restart, or signed by a key not in the lock", { skip: skipMesh, timeout: 120_000 }, async () => {
  const WS = "01HZZZZZZZZZZZZZZZZZZZZT92";
  const VAULT = "v_01HZZZZZZZZZZZZZZZZZZZZT92";
  const env = await lockedStation({ ws: WS, vaultId: VAULT, tag: "boxes" });
  const device = env.client.id();
  const shown = async (conn: Connection) => {
    const [st, body] = await memberAsk(conn, "GET", "/admin/api/vault/boxes");
    assert.equal(st, 200, JSON.stringify(body));
    const mine = body.boxes.find((b: any) => b.device === device);
    assert.ok(mine, `the device's box is listed: ${JSON.stringify(body)}`);
    return mine.cert ?? mine;
  };
  const base = env.cert.at;
  const certAt = (at: number) => {
    const box = newBoxPair();
    return signed({ v: 1 as const, ws: WS, device, box: box.pub, at }, TAG.box, env.aliceSigner);
  };

  // Each round: an older and a newer one put at once, in either order; the newest of all is what stays.
  let newest: BoxCert = env.cert;
  for (let round = 1; round <= 4; round++) {
    const newer = certAt(base + 10 * round);
    const older = certAt(base + 10 * round - 5 - 10);
    const order = round % 2 === 0 ? [newer, older] : [older, newer];
    const answers = await Promise.all(order.map((c) => memberAsk(env.conn, "PUT", "/admin/api/vault/boxes", c)));
    for (const [i, [st, body]] of answers.entries()) {
      assert.equal(st, 200, JSON.stringify(body));
      assert.ok(body.box.at >= Math.max(order[i]!.at, newest.at), `no answer goes back before what was put or held: ${JSON.stringify(body)}`);
    }
    newest = newer;
    const now = await shown(env.conn);
    assert.equal(now.box, newer.box, `round ${round}: the newer certificate stays`);
    assert.equal(now.at, newer.at);
  }

  // Signed by a key the lock does not give this device: refused, the newest kept.
  const stranger = ed();
  const forged = signed({ v: 1 as const, ws: WS, device, box: newBoxPair().pub, at: newest.at + 100 }, TAG.box, stranger);
  const [forgedSt, forgedBody] = await memberAsk(env.conn, "PUT", "/admin/api/vault/boxes", forged);
  assert.notEqual(forgedSt, 200, `a certificate signed by a key not in the lock is refused: ${JSON.stringify(forgedBody)}`);
  assert.equal((await shown(env.conn)).box, newest.box);

  // After a cold restart the replayed older ones still do not win.
  await stop(env.launched);
  const again = await env.start();
  assert.equal((await shown(again.conn)).box, newest.box, "the newest certificate kept over a restart");
  for (const stale of [env.cert, certAt(newest.at - 1)]) {
    const [st, body] = await memberAsk(again.conn, "PUT", "/admin/api/vault/boxes", stale);
    assert.equal(st, 200, JSON.stringify(body));
    assert.equal(body.box.box, newest.box, "an older certificate replayed after the restart does not replace the newest");
  }
  assert.equal((await shown(again.conn)).box, newest.box);
  await stop(again.launched);
});

test("on startup: expired grants let go in batches while the station serves, live and idle-renewed ones usable at once, an archived chat's grants and waiting sign-in not taken up, another session's grant refused", { skip: skipBase, timeout: 120_000 }, async () => {
  const WS = "ws-restore-edges";
  const VALUE = "restore-edges-s3cr3t-3307";
  const env = await plainStation("restore", WS, [
    { key: "s1", token: "t1" },
    { key: "s2", token: "t2" },
    { key: "s3", token: "t3", archived: true },
  ]);
  const now = Math.floor(Date.now() / 1000);
  const expired = Array.from({ length: 70 }, (_, i) => `r_01HZZZZZZZZZZZZZZZZZZE${String(i).padStart(4, "0")}`);
  const LIVE = "r_01HZZZZZZZZZZZZZZZZZZZRL01";
  const IDLE = "r_01HZZZZZZZZZZZZZZZZZZZRI01";
  const ARCHIVED = "r_01HZZZZZZZZZZZZZZZZZZZRA01";
  const SPENT_IDLE = "r_01HZZZZZZZZZZZZZZZZZZZRI02";
  seedPlain(env.data, WS, { id: "ip-restore", name: "Restore Token", value: VALUE, env: "RESTORE_TOK" }, [
    // expired among the live ones, more than one batch of them (32)
    ...expired.slice(0, 35).map((id) => ({ id, session: "s1", scope: "hour" as const, exp: now - 3600, at: now - 7200 })),
    { id: LIVE, session: "s1", scope: "hour", exp: now + 3600, at: now - 10 },
    ...expired.slice(35).map((id) => ({ id, session: "s2", scope: "hour" as const, exp: now - 60, at: now - 3660 })),
    // past its approval's expiry, kept on by a use before the restart
    { id: IDLE, session: "s1", scope: "hour", exp: now - 30, at: now - 1830, timeout: { kind: "idle", seconds: 1800 }, until: now + 1200, uses: 2 },
    // idle, its renewal run out as well
    { id: SPENT_IDLE, session: "s1", scope: "hour", exp: now - 300, at: now - 2100, timeout: { kind: "idle", seconds: 1800 }, until: now - 5, uses: 4 },
    { id: ARCHIVED, session: "s3", scope: "chat", exp: now + 86400, at: now - 10 },
  ]);
  // A sign-in the archived chat waited for, and one a live chat waits for.
  const signinBody = (id: string, session: string) => JSON.stringify({
    id, ws: WS, vault: "plain", item: "ip-restore", session, chat: `CHAT/${session}`, owner: "owner@local", mode: "browser",
    hosts: ["example.com"], reason: "sign in", box: "", at: now - 5, status: "pending", signin: { site: "example.com" },
  });
  const ARCHIVED_SIGNIN = "r_01HZZZZZZZZZZZZZZZZZZZSA01";
  withDb(env.data, (db) => {
    db.prepare("INSERT INTO vault_requests (ws, id, session, status, body) VALUES (?, ?, ?, 'pending', ?)").run(WS, ARCHIVED_SIGNIN, "s3", signinBody(ARCHIVED_SIGNIN, "s3"));
  });

  const a = await launch(env.data, env.app);
  await a.next("ready", (m) => m.ready === true);
  const door = (await a.next("mcp", (m) => m.serving === "mcp")).port as number;

  // Served at once: the live grant runs on the first ask, with its value hidden.
  const out = join(env.work, "live.txt");
  const live = await tool(door, "t1", "secret_run", { grant: LIVE, command: `printf '%s' "$RESTORE_TOK" > "${out}"; printf 'live:%s' "$RESTORE_TOK"` });
  assert.equal(live.error, false, live.text);
  assert.equal(readFileSync(out, "utf8"), VALUE);
  assert.ok(!live.text.includes(VALUE), live.text);

  const remaining = withDb(env.data, (db) => (db.prepare("SELECT id FROM vault_grants WHERE ws = ? ORDER BY id").all(WS) as { id: string }[]).map((r) => r.id), true);
  assert.deepEqual(remaining.filter((id) => expired.includes(id)), [], "every expired grant let go on startup, across batches");
  assert.ok(!remaining.includes(SPENT_IDLE), "an idle grant whose renewal ran out let go");
  assert.ok(!remaining.includes(ARCHIVED), "an archived chat's grant not taken up again");
  assert.ok(remaining.includes(LIVE) && remaining.includes(IDLE), `live grants kept: ${JSON.stringify(remaining)}`);

  // Kept on by its use before the restart: usable past its approval's expiry.
  const idle = await tool(door, "t1", "secret_run", { grant: IDLE, command: `printf 'idle:%s' "$RESTORE_TOK"` });
  assert.equal(idle.error, false, idle.text);
  assert.ok(!idle.text.includes(VALUE));
  const spent = await tool(door, "t1", "secret_run", { grant: SPENT_IDLE, command: "printf no" });
  assert.equal(spent.error, true, spent.text);

  // Another session, live or archived, never uses s1's grant, nor its own from an archived chat.
  for (const [token, grant, why] of [["t2", LIVE, /another session's/], ["t2", IDLE, /another session's/], ["t3", LIVE, /another session's/], ["t3", ARCHIVED, /no such grant/]] as const) {
    const r = await tool(door, token, "secret_run", { grant, command: `printf 'leak:%s' "$RESTORE_TOK"` });
    assert.equal(r.error, true, `${token} using ${grant} refused: ${r.text}`);
    assert.match(r.text, why);
    assert.ok(!r.text.includes(VALUE) && !r.text.includes("leak:"), `nothing of it ran: ${r.text}`);
  }

  // The archived chat's waiting sign-in: not asked again, nor anything it waited for listed as its own.
  const reask = await tool(door, "t3", "secret_reask", { request: ARCHIVED_SIGNIN });
  assert.equal(reask.error, true, `an archived chat's sign-in is not asked again: ${reask.text}`);
  const listed = await tool(door, "t3", "secret_list", {});
  assert.ok(!listed.text.includes(ARCHIVED) && !listed.text.includes(VALUE), `an archived chat holds nothing: ${listed.text}`);
  const signinRow = withDb(env.data, (db) => db.prepare("SELECT status FROM vault_requests WHERE ws = ? AND id = ?").get(WS, ARCHIVED_SIGNIN) as { status: string } | undefined, true);
  assert.notEqual(signinRow?.status, "granted", "the archived chat's sign-in never granted");

  assert.doesNotMatch(a.err(), new RegExp(VALUE), "the value is never logged");
  await stop(a);
});
