// The station's own parts of P5-4 as the MoonBit program runs them (station/mb src/station_main live_p5_4_*.mbt), in
// `run` under a launcher of the test's with no Node on its PATH: the vault's tools on the agents' door and what it
// holds in memory carried over to the next process at a handover (`carry.vault`), the drive on config.json's roots
// reading and writing there and refusing the station's own data directory, the terminals opened only on the test
// channel (features.ts `stationFeature("terminal")`), and the browser's, the devices' and the logins' parts there:
// their tools listed, their routes and the browser's place on the door. What the parts answer by name (the bus's
// `ui_ask`, as the admin API's routes ask it) is reached through the test's door (`STILLFAIL_TEST_UI_ASK`).
import assert from "node:assert/strict";
import { type ChildProcess, spawn, spawnSync } from "node:child_process";
import { generateKeyPairSync, verify as verifySignature } from "node:crypto";
import { linkSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { type AddressInfo, connect as netConnect, createConnection, createServer, type Server, type Socket } from "node:net";
import { createServer as httpServer, request } from "node:http";
import { networkInterfaces, tmpdir } from "node:os";
import { connect as tlsConnect } from "node:tls";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { DatabaseSync } from "node:sqlite";
import { after, test } from "node:test";
import { WebSocketServer } from "ws";
import { mbStationBinary } from "./mb-harness.ts";
import { Store } from "../src/store/store.ts";

const binary = mbStationBinary();
const skip = binary === null ? "the MoonBit program (stillfail-reader) is not built here" : process.platform === "win32" ? "the launcher's descriptors are Unix's" : false;

const dirs: string[] = [];
// (short: a Unix socket's path is at most 104 bytes on macOS)
const fresh = (what: string) => {
  const dir = mkdtempSync(join(tmpdir(), `sf-${what}-`));
  dirs.push(dir);
  return dir;
};
const children: ChildProcess[] = [];
after(async () => {
  const left = children.filter((c) => c.exitCode === null && c.signalCode === null);
  for (const c of left) c.kill("SIGKILL");
  await Promise.all(left.map((c) => (c.exitCode === null && c.signalCode === null ? new Promise<void>((r) => c.once("exit", () => r())) : undefined)));
  for (const d of dirs) rmSync(d, { recursive: true, force: true });
});

const TOKEN = "p5-4-test-door";

/// An environment with no Node: an empty PATH of its own, HOME and TMPDIR as given, the test's door opened.
const noNode = (more: Record<string, string> = {}) => ({ PATH: fresh("path"), HOME: process.env.HOME ?? tmpdir(), TMPDIR: tmpdir(), STILLFAIL_TEST_UI_ASK: TOKEN, ...more });

type Launched = { child: ChildProcess; said: any[]; next: (what: string, ok: (m: any) => boolean) => Promise<any>; tell: (m: unknown) => void; ended: Promise<number | null> };

/// The program's `run` with the launcher's descriptors (ops/launcher.ts): its listeners bound here and handed down, its
/// control channel the fourth's pipe.
async function launch(data: string, app: string, more: Record<string, string> = {}): Promise<Launched> {
  const listener = () => new Promise<Server>((resolve) => {
    const s = createServer();
    s.listen(0, "127.0.0.1", () => resolve(s));
  });
  const [mcp, loop] = [await listener(), await listener()];
  const fd = (s: Server) => (s as any)._handle.fd as number;
  const child = spawn(binary!, ["run", "--app", app, "--data", data, "--launcher-fds", "3,4,5", "--launcher-carries", "--launcher-heartbeat"], {
    stdio: ["ignore", "pipe", "pipe", fd(mcp), fd(loop), "pipe"],
    env: noNode({ STILLFAIL_HELD_EVERY_MS: "300", ...more }),
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
      const timer = setTimeout(() => reject(new Error(`never said: ${what}; said ${JSON.stringify(said)}; stderr ${err}`)), 15_000);
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
  return { child, said, next, tell: (m) => channel.write(`${JSON.stringify(m)}\n`), ended };
}

function http(port: number, path: string, body?: string, headers: Record<string, string> = {}): Promise<{ status: number; body: string }> {
  return new Promise((resolve, reject) => {
    const req = request({ host: "127.0.0.1", port, path, method: body === undefined ? "GET" : "POST", headers: { "content-type": "application/json", ...headers } }, (res) => {
      let text = "";
      res.on("data", (d) => (text += d));
      res.on("end", () => resolve({ status: res.statusCode!, body: text }));
    });
    req.on("error", reject);
    req.end(body);
  });
}

/// What the parts answer by name, through the test's door.
async function ask(port: number, op: string, args: unknown[] = []): Promise<{ answer?: any; error?: any; kind?: string }> {
  const got = await http(port, "/ui-ask/", JSON.stringify({ op, args }), { authorization: `Bearer ${TOKEN}` });
  return JSON.parse(got.body);
}

/// The agents' door, as the session whose bearer `token` is asks it.
const mcp = async (port: number, token: string, method: string, params: unknown = {}) => {
  const r = await http(port, "/mcp", JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }), { authorization: `Bearer ${token}` });
  assert.equal(r.status, 200, r.body);
  return JSON.parse(r.body);
};

const config = (data: string, c: unknown) => writeFileSync(join(data, "config.json"), JSON.stringify(c));

test("run: the vault, the drive, the screens, the browser, the devices, the terminals and the logins made live; the vault's memory carried over a handover", { skip }, async () => {
  const data = fresh("p54");
  const app = fresh("app");
  const root = fresh("root");
  writeFileSync(join(app, "BUILD"), "9500\n");
  config(data, { updateChannel: "stable", drive: { roots: [root] } });
  const a = await launch(data, app, { STILLFAIL_LOCAL_ADMIN: "1" });
  await a.next("ready", (m) => m.ready === true);
  const door = (await a.next("mcp", (m) => m.serving === "mcp")).port as number;

  // the parts' tools, on the agents' door, as a session asks them
  const store = Store.open(join(data, "stillfail.db"), join(data, "archive"), { currentTimeMillisUnsafe: () => Date.now() } as never);
  store.insertSession({ key: "s1", connect: "ember", runtime: "claude", profile: "cc", workspace: root, token: "t1", createdAt: Date.now(), lastActiveAt: Date.now() });
  store.close();
  const listed = (await mcp(door, "t1", "tools/list")).result.tools.map((t: any) => t.name).sort();
  for (const name of ["secret_list", "secret_use", "secret_run", "secret_save", "secret_describe", "secret_delete", "secret_cancel", "sign_in", "browser", "device_list", "device_use", "phone_send", "login", "screen", "computer"]) {
    assert.ok(listed.includes(name), `${name} among the tools (${listed.join(", ")})`);
  }
  for (const hidden of ["secret_reask", "phone_use", "adb_devices"]) {
    assert.ok(!listed.includes(hidden), `${hidden} hidden from tools/list`);
  }
  assert.equal(new Set(listed).size, listed.length, "each tool once");
  const secrets = (await mcp(door, "t1", "tools/call", { name: "secret_list", arguments: {} })).result;
  assert.equal(secrets.content[0].type, "text");
  assert.equal(typeof secrets.content[0].text, "string");
  const devices = (await mcp(door, "t1", "tools/call", { name: "device_list", arguments: {} })).result;
  assert.equal(devices.content[0].type, "text");

  // the vault's routes' own asks: no lock pinned here, the plain library of a workspace
  assert.deepEqual(await ask(door, "vault.lock", [null]), { answer: null });
  assert.deepEqual(await ask(door, "secrets.plain.items", ["ws1", "a@example.com"]), { answer: [] });

  // the drive: config.json's root read and written, the station's own data directory never reached
  assert.deepEqual((await ask(door, "drive.roots")).answer.map((r: any) => r.path), [root]);
  const up = await ask(door, "drive.upload", [root, "hello.txt", "u1", 0, 5, { $bytes: Buffer.from("hello").toString("base64") }, false, true]);
  assert.equal(up.answer.size, 5, JSON.stringify(up));
  assert.equal(readFileSync(join(root, "hello.txt"), "utf8"), "hello", "written where the root is");
  const read = await ask(door, "drive.read", [root, "hello.txt", 0, 1024, true]);
  assert.equal(Buffer.from(read.answer.bytes.$bytes, "base64").toString("utf8"), "hello");
  assert.equal(read.answer.total, 5);
  const list = await ask(door, "drive.list", [root, "", true]);
  assert.deepEqual(list.answer.entries.map((e: any) => e.name), ["hello.txt"]);
  const own = await ask(door, "drive.list", [data, "", false]);
  assert.equal(own.kind, "DriveError", JSON.stringify(own));
  assert.equal(own.error.code, "not_a_root");
  const ownAnywhere = await ask(door, "drive.list", [data, "", true]);
  assert.equal(ownAnywhere.kind, "DriveError", JSON.stringify(ownAnywhere));
  assert.equal(ownAnywhere.error.code, "protected", "the station's own, even to a member who may go anywhere");
  // a file of the drive staged among the uploads for a message, and a folder zipped there
  // (through the admin API's own route, as its owner: the place in the uploads is the route's to give, called back)
  const stage = async (path: string, zip: boolean) => {
    const r = await http(door, "/admin-api/drive/stage", JSON.stringify({ root, path, zip }));
    return { status: r.status, body: JSON.parse(r.body) };
  };
  const staged = await stage("hello.txt", false);
  assert.equal(staged.body.name, "hello.txt", JSON.stringify(staged));
  assert.equal(staged.body.size, 5);
  assert.equal(readFileSync(staged.body.path, "utf8"), "hello");
  assert.ok(staged.body.path.startsWith(join(data, "uploads")), staged.body.path);
  mkdirSync(join(root, "folder"));
  writeFileSync(join(root, "folder", "a.txt"), "aaa");
  const zipped = await stage("folder", true);
  assert.equal(zipped.body.name, "folder.zip", JSON.stringify(zipped));
  assert.equal(readFileSync(zipped.body.path).subarray(0, 2).toString("latin1"), "PK", "a zip");
  const notZipped = await stage("folder", false);
  assert.equal(notZipped.body.code, "is_a_directory", JSON.stringify(notZipped));
  const ownWrite = await ask(door, "drive.upload", [data, "x.txt", "u2", 0, 1, { $bytes: "eA==" }, false, true]);
  assert.equal(ownWrite.error?.code, "protected", JSON.stringify(ownWrite));
  // a root naming the data directory is shown, and still refused
  config(data, { updateChannel: "stable", drive: { roots: [root, data] } });
  const both = await ask(door, "drive.list", [data, "", true]);
  assert.equal(both.error?.code, "protected", JSON.stringify(both));

  // the terminals: a new one only on the test channel, as config.json says now
  assert.deepEqual(await ask(door, "terminals.offered"), { answer: false });
  config(data, { updateChannel: "beta", drive: { roots: [root] } });
  assert.deepEqual(await ask(door, "terminals.offered"), { answer: true });
  assert.deepEqual(await ask(door, "terminals.list", ["ws1"]), { answer: [] });
  config(data, { updateChannel: "stable", drive: { roots: [root] } });
  assert.deepEqual(await ask(door, "terminals.offered"), { answer: false });

  // the parts' routes of the admin API and the browser's place on the door
  const routes = (await ask(door, "p54.routes")).answer;
  for (const r of ["GET ^/terminals$", "POST ^/terminals/([^/]+)/end$", "GET ^/devices$", "POST ^/devices$"]) assert.ok(routes.includes(r), `${r} among ${routes}`);
  const browser = await http(door, "/browser/c2Vzc2lvbg");
  assert.equal(browser.status, 400);
  assert.match(browser.body, /WebSocket/);
  assert.deepEqual(await ask(door, "logins.logins"), { answer: [] });
  assert.equal(Array.isArray((await ask(door, "screens.list")).answer), true);

  // P1-1: accounts_oauth host_io atomic mkdir(recursive=false) EEXIST + hold.utimes on lock dir
  const oauthLock = (await ask(door, "p54.oauthHostLock")).answer;
  assert.equal(oauthLock.eexist, "EEXIST", JSON.stringify(oauthLock));
  assert.ok(Math.abs(oauthLock.mtimeMs - 1_700_000_555_000) < 2, JSON.stringify(oauthLock));
  assert.equal(oauthLock.afterRemove, "ENOENT", JSON.stringify(oauthLock));

  // P1-2: P51::member_screens passes raw @door.Stream + media_datagrams directly to answer_screen
  const screenDgram = (await ask(door, "p54.memberScreensDatagrams")).answer;
  assert.deepEqual(screenDgram.tokens, [42], JSON.stringify(screenDgram));
  const screenHead = JSON.parse(screenDgram.firstLine);
  assert.equal(screenHead.status, 200, JSON.stringify(screenHead));
  assert.equal(screenHead.headers?.["x-screen-dgram"], "42", JSON.stringify(screenHead));

  // a handover: what the vault holds in memory carried to the next process, and taken up there
  const b = await launch(data, app);
  await b.next("ready", (m) => m.ready === true);
  a.tell({ op: "handover" });
  const carry = await a.next("carry", (m) => m.carry !== undefined);
  assert.equal(typeof carry.carry.vault, "object", JSON.stringify(carry));
  assert.notEqual(carry.carry.vault, null);
  assert.equal(await a.ended, 0);
  b.tell({ op: "carried", carried: carry.carry });
  const bDoor = (await b.next("serving the agents' door", (m) => m.serving === "mcp")).port as number;
  assert.deepEqual((await ask(bDoor, "vault.carried")).answer, carry.carry.vault, "taken up as it was given");
  b.tell({ op: "stop" });
  assert.equal(await b.ended, 0);
});

test("run: the vault's and the phones' cards posted in a still.fail chat (hub.post, chat.post), said by the session's agent", { skip }, async () => {
  const data = fresh("p54c");
  const app = fresh("app");
  writeFileSync(join(app, "BUILD"), "9500\n");
  config(data, { updateChannel: "stable" });
  const a = await launch(data, app);
  await a.next("ready", (m) => m.ready === true);
  const door = (await a.next("mcp", (m) => m.serving === "mcp")).port as number;

  // two sessions, each in a still.fail chat of its own that alice started
  const store = Store.open(join(data, "stillfail.db"), join(data, "archive"), { currentTimeMillisUnsafe: () => Date.now() } as never);
  const chats = new Map<string, number>();
  for (const [key, ts] of [["vault", "1795000000.000100"], ["phone", "1795000000.000200"]] as const) {
    store.insertSession({ key, connect: "chat", runtime: "claude", profile: "cc", workspace: fresh("ws"), token: `t-${key}`, createdBy: "alice@x.com", ws: "ws1", createdAt: Date.now(), lastActiveAt: Date.now() });
    const thread = store.openThread("chat", "CHAT", ts, null, "alice@x.com");
    store.joinThread(thread.id, key, "chat");
    chats.set(key, thread.id);
  }
  store.close();
  const call = async (token: string, name: string, args: unknown) => {
    const got = (await mcp(door, token, "tools/call", { name, arguments: args })).result;
    const text = got.content.map((c: any) => c.text).join("\n");
    assert.doesNotMatch(text, /no hub call/, text);
    assert.notEqual(got.isError, true, text);
    return text;
  };
  const cards = (thread: number) => {
    const db = new DatabaseSync(join(data, "stillfail.db"), { readOnly: true });
    try {
      return (db.prepare("SELECT ts, text, card FROM entries WHERE thread = ? AND kind = 'message' AND card IS NOT NULL ORDER BY n").all(thread) as { ts: string; text: string; card: string }[])
        .map((r) => ({ ts: r.ts, text: r.text, card: JSON.parse(r.card) }));
    } finally {
      db.close();
    }
  };

  // secret_save, typed in on its card: the vault's card said through `hub.post` in the chat it was asked in
  await call("t-vault", "secret_save", { kind: "token", name: "Test API token", about: "for the test", reason: "the test keeps it" });
  const vault = cards(chats.get("vault")!);
  assert.equal(vault.length, 1, JSON.stringify(vault));
  assert.equal(typeof vault[0]!.card.vault, "object", JSON.stringify(vault[0]));
  assert.equal(vault[0]!.card.assignee, "alice@x.com");
  assert.match(vault[0]!.ts, /^\d+\.\d+$/, "a still.fail chat's own ts");

  // phone_use: the phones' card said through `chat.post`
  await call("t-phone", "phone_use", { reason: "the test debugs the app" });
  const phone = cards(chats.get("phone")!);
  assert.equal(phone.length, 1, JSON.stringify(phone));
  assert.equal(typeof phone[0]!.card.adb, "object", JSON.stringify(phone[0]));
  assert.equal(phone[0]!.card.assignee, "alice@x.com");

  a.tell({ op: "stop" });
  assert.equal(await a.ended, 0);
});

/// An SSH agent's message (RFC draft-miller-ssh-agent): its length, its type, its payload.
const sshString = (b: Buffer) => Buffer.concat([Buffer.from([b.length >>> 24, (b.length >>> 16) & 255, (b.length >>> 8) & 255, b.length & 255]), b]);
const u32 = (n: number) => Buffer.from([n >>> 24, (n >>> 16) & 255, (n >>> 8) & 255, n & 255]);
function agentAsk(path: string, message: Buffer): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    const s = createConnection(path);
    let got = Buffer.alloc(0);
    s.on("data", (d) => {
      got = Buffer.concat([got, d]);
      if (got.length >= 4 && got.length >= 4 + got.readUInt32BE(0)) {
        s.end();
        resolve(got.subarray(4, 4 + got.readUInt32BE(0)));
      }
    });
    s.on("error", reject);
    s.write(Buffer.concat([u32(message.length), message]));
  });
}
function readString(b: Buffer, at: number): [Buffer, number] {
  const n = b.readUInt32BE(at);
  return [b.subarray(at + 4, at + 4 + n), at + 4 + n];
}

/// A request through the vault's proxy: CONNECT with its run's credentials, TLS with its CA (`options` as Node's), one
/// GET; the answer's head and body.
function throughProxy(proxyUrl: string, bundle: string, host: string, header: string, options: Record<string, unknown> = {}): Promise<{ text: string; cipher: string; group: string; version: string }> {
  const u = new URL(proxyUrl);
  return new Promise((resolve, reject) => {
    const raw = netConnect(Number(u.port), "127.0.0.1", () => {
      raw.write(`CONNECT ${host}:443 HTTP/1.1\r\nhost: ${host}:443\r\nproxy-authorization: Basic ${Buffer.from(`${u.username}:${u.password}`).toString("base64")}\r\n\r\n`);
    });
    let head = "";
    const onHead = (d: Buffer) => {
      head += d.toString("latin1");
      if (!head.includes("\r\n\r\n")) return;
      raw.off("data", onHead);
      if (!head.startsWith("HTTP/1.1 200")) return reject(new Error(`the proxy said ${head}`));
      const tls = tlsConnect({ socket: raw as Socket, servername: host, ca: readFileSync(bundle), minVersion: "TLSv1.3", ...options }, () => {
        tls.write(`GET /hello HTTP/1.1\r\nhost: ${host}\r\nauthorization: ${header}\r\nconnection: close\r\n\r\n`);
      });
      let text = "";
      let cipher = "", group = "", version = "";
      tls.on("secureConnect", () => {
        cipher = tls.getCipher().name;
        version = tls.getProtocol() ?? "";
        group = String((tls.getEphemeralKeyInfo() as any)?.name ?? "");
      });
      tls.on("data", (b) => (text += b.toString("utf8")));
      tls.on("end", () => resolve({ text, cipher, group, version }));
      tls.on("close", () => resolve({ text, cipher, group, version }));
      tls.on("error", reject);
    };
    raw.on("data", onHead);
    raw.on("error", reject);
  });
}

test("run: the vault's SSH agent and its HTTPS proxy, and a device's TCP on any address of this machine", { skip }, async () => {
  // the host the proxy sends on to (a test's: plain HTTP on this machine, STILLFAIL_TEST_PROXY_UPSTREAM)
  const seen: string[] = [];
  const upstream = httpServer((req, res) => {
    seen.push(String(req.headers.authorization));
    res.writeHead(200, { "content-type": "text/plain" });
    res.end(`hello ${req.url}`);
  });
  await new Promise<void>((r) => upstream.listen(0, "127.0.0.1", () => r()));
  const upPort = (upstream.address() as any).port as number;
  // a device on this machine's network (its first address that is not loopback), echoing what it is sent
  const lan = Object.values(networkInterfaces()).flat().find((i) => i && i.family === "IPv4" && !i.internal)?.address ?? null;
  const echo = createServer((s) => s.on("data", (d) => s.write(Buffer.concat([Buffer.from("echo:"), d]))));
  await new Promise<void>((r) => echo.listen(0, "0.0.0.0", () => r()));
  const echoPort = (echo.address() as any).port as number;
  try {
    const data = fresh("p54x");
    const app = fresh("appx");
    writeFileSync(join(app, "BUILD"), "9500\n");
    const a = await launch(data, app, { STILLFAIL_TEST_PROXY_UPSTREAM: String(upPort) });
    await a.next("ready", (m) => m.ready === true);
    const door = (await a.next("mcp", (m) => m.serving === "mcp")).port as number;

    // the SSH agent: an Ed25519 key and an RSA key, each listed and each signing as asked
    const keys = fresh("keys");
    const cases: [string, any, number][] = [
      ["ed25519", generateKeyPairSync("ed25519"), 0],
      ["rsa", generateKeyPairSync("rsa", { modulusLength: 2048 }), 2],
      ["rsa", generateKeyPairSync("rsa", { modulusLength: 2048 }), 4],
      ["rsa", generateKeyPairSync("rsa", { modulusLength: 2048 }), 0],
    ];
    for (const [i, [kind, pair, flags]] of cases.entries()) {
      const sock = join(keys, `agent-${i}.sock`);
      const pem = pair.privateKey.export({ format: "pem", type: "pkcs8" }) as string;
      const made = await ask(door, "test.sshAgent", [pem, sock]);
      assert.equal(made.answer?.kind, kind === "ed25519" ? "ssh-ed25519" : "ssh-rsa", JSON.stringify(made));
      const ids = await agentAsk(sock, Buffer.from([11]));
      assert.equal(ids[0], 12, "identities");
      assert.equal(ids.readUInt32BE(1), 1);
      const [blob] = readString(ids, 5);
      assert.equal(blob.toString("hex"), made.answer.blob);
      const data = Buffer.from(`sign me ${i}`);
      const signed = await agentAsk(sock, Buffer.concat([Buffer.from([13]), sshString(blob), sshString(data), u32(flags)]));
      assert.equal(signed[0], 14, "a signature");
      const [sig] = readString(signed, 1);
      const [name, at] = readString(sig, 0);
      const [bytes] = readString(sig, at);
      const pub = pair.publicKey;
      if (kind === "ed25519") {
        assert.equal(name.toString(), "ssh-ed25519");
        assert.ok(verifySignature(null, data, pub, bytes), "Ed25519 signature checks");
      } else {
        const hash = flags === 2 ? "sha256" : flags === 4 ? "sha512" : "sha1";
        assert.equal(name.toString(), flags === 2 ? "rsa-sha2-256" : flags === 4 ? "rsa-sha2-512" : "ssh-rsa");
        assert.ok(verifySignature(hash, data, pub, bytes), `RSA ${hash} signature checks`);
      }
    }

    // the HTTPS proxy: a host the run may reach opened with the proxy's leaf, the placeholder swapped on the way
    const proxy = (await ask(door, "test.proxy", [["api.example.test"], "stillfail-secret:g1", "s3cr3t-value"])).answer;
    assert.match(proxy.url, /^http:\/\/run:[^@]+@127\.0\.0\.1:\d+$/);
    const ways: [Record<string, unknown>, string, string][] = [
      [{}, "TLS_CHACHA20_POLY1305_SHA256", "X25519"],
      [{ ciphers: "TLS_AES_128_GCM_SHA256" }, "TLS_AES_128_GCM_SHA256", "X25519"],
      [{ ecdhCurve: "P-256" }, "TLS_CHACHA20_POLY1305_SHA256", "prime256v1"],
      [{ ciphers: "TLS_AES_128_GCM_SHA256", ecdhCurve: "P-256" }, "TLS_AES_128_GCM_SHA256", "prime256v1"],
    ];
    for (const [options, cipher, group] of ways) {
      const said = await throughProxy(proxy.url, proxy.bundle, "api.example.test", "Bearer stillfail-secret:g1", options);
      assert.equal(said.version, "TLSv1.3");
      assert.equal(said.cipher, cipher, JSON.stringify(options));
      assert.equal(said.group, group, JSON.stringify(options));
      assert.match(said.text, /^HTTP\/1\.1 200/, `${JSON.stringify(options)}: ${said.text}`);
      assert.match(said.text, /hello \/hello$/);
    }
    assert.deepEqual(seen.slice(0, 4), ["Bearer s3cr3t-value", "Bearer s3cr3t-value", "Bearer s3cr3t-value", "Bearer s3cr3t-value"], "the secret put in on the way, never seen by the command");
    // curl as a command run with the secret uses it (its own TLS, ALPN offering h2 and http/1.1), where it is here
    const curl = spawnSync("curl", ["--version"], { encoding: "utf8" });
    if (curl.status === 0) {
      // (not spawnSync: the host it reaches is this process's)
      const got = await new Promise<{ status: number | null; stdout: string; stderr: string }>((resolve) => {
        const c = spawn("curl", ["-sS", "--proxy", proxy.url, "--cacert", proxy.bundle, "-H", "authorization: Bearer stillfail-secret:g1", "https://api.example.test/hello"]);
        let stdout = "", stderr = "";
        c.stdout.on("data", (d) => (stdout += d));
        c.stderr.on("data", (d) => (stderr += d));
        c.on("close", (status) => resolve({ status, stdout, stderr }));
      });
      assert.equal(got.status, 0, got.stderr);
      assert.equal(got.stdout, "hello /hello");
      assert.equal(seen.at(-1), "Bearer s3cr3t-value");
    }
    // a host the run may not reach with its secret: carried through as it is, nothing opened or swapped
    const through = lan ?? "127.0.0.1";
    const tunneled = await new Promise<string>((resolve, reject) => {
      const u = new URL(proxy.url);
      const s = netConnect(Number(u.port), "127.0.0.1", () => {
        s.write(`CONNECT ${through}:${echoPort} HTTP/1.1\r\nproxy-authorization: Basic ${Buffer.from(`${u.username}:${u.password}`).toString("base64")}\r\n\r\n`);
      });
      let t = "";
      s.on("data", (d) => {
        t += d;
        if (t === "HTTP/1.1 200 Connection Established\r\n\r\n") s.write("stillfail-secret:g1");
        if (t.endsWith("echo:stillfail-secret:g1")) {
          s.end();
          resolve(t);
        }
      });
      s.on("error", reject);
    });
    assert.match(tunneled, /echo:stillfail-secret:g1$/, "carried as it was");
    // with no credentials, refused
    const refused = await new Promise<string>((resolve) => {
      const s = netConnect(Number(new URL(proxy.url).port), "127.0.0.1", () => s.write("CONNECT api.example.test:443 HTTP/1.1\r\n\r\n"));
      let t = "";
      s.on("data", (d) => (t += d));
      s.on("close", () => resolve(t));
      s.on("end", () => resolve(t));
    });
    assert.match(refused, /^HTTP\/1\.1 407/);

    // a device's TCP: this machine's own and, where it has one, an address of its network
    assert.deepEqual(await ask(door, "test.reachTcp", ["127.0.0.1", echoPort, "ping"]), { answer: "echo:ping" });
    if (lan !== null) assert.deepEqual(await ask(door, "test.reachTcp", [lan, echoPort, "lan"]), { answer: "echo:lan" });
    const nowhere = await ask(door, "test.reachTcp", ["no-such-host.invalid", 9, "x"]);
    assert.equal(nowhere.kind, "Error", JSON.stringify(nowhere));

    // a connection of live_p5_4_io.c's read to its end lets its slot go; one called off as it connects too
    const held = (await ask(door, "test.ioHeld")).answer as number;
    const closer = createServer((s) => s.end("bye"));
    await new Promise<void>((r) => closer.listen(0, "0.0.0.0", () => r()));
    const eof = (await ask(door, "test.netEof", [lan ?? "127.0.0.1", (closer.address() as any).port])).answer;
    closer.close();
    assert.equal(eof.got, "bye");
    assert.equal(eof.held, held + 1, "held while open");
    assert.equal(eof.after, held, "let go at its end");
    const calledOff = (await ask(door, "test.netCalledOff", ["192.0.2.1", 9, 150])).answer;
    assert.equal(calledOff.held, held, "let go as it was called off");
    assert.ok(calledOff.elapsedMs < 2000, `connecting slot aborted promptly: ${calledOff.elapsedMs}ms`);

    // backpressured peer (paused reader): p54io_write never blocks the event loop, rejects at queue cap, and close cleans up
    const pausedSockets: Socket[] = [];
    const stall = createServer((s) => {
      s.pause();
      pausedSockets.push(s);
    });
    await new Promise<void>((r) => stall.listen(0, "127.0.0.1", () => r()));
    try {
      const bp = (await ask(door, "test.netBackpressure", ["127.0.0.1", (stall.address() as any).port])).answer;
      assert.equal(bp.hitFull, true, `write queue cap hit: ${JSON.stringify(bp)}`);
      assert.ok(bp.elapsedMs < 3000, `non-blocking write returned promptly: ${bp.elapsedMs}ms`);
      assert.equal(bp.heldAfter, held, "slot released after close");
    } finally {
      for (const s of pausedSockets) s.destroy();
      stall.close();
    }

    // write + end ordering: all queued bytes arrive before EOF
    const sink = createServer((s) => {
      let total = 0;
      let bad = false;
      s.on("data", (d: Buffer) => {
        total += d.length;
        for (let i = 0; i < d.length; i++) if (d[i] !== 0x61) bad = true;
      });
      s.on("end", () => s.end(bad ? "bad" : `ok:${total}`));
    });
    await new Promise<void>((r) => sink.listen(0, "127.0.0.1", () => r()));
    try {
      const ordered = (await ask(door, "test.netWriteEndOrder", ["127.0.0.1", (sink.address() as any).port, 16])).answer;
      assert.equal(ordered.allWritten, true, JSON.stringify(ordered));
      assert.equal(ordered.reply, `ok:${16 * 65536}`);
      assert.equal(ordered.heldAfter, held, "slot released after ordered write+end");
    } finally {
      sink.close();
    }

    // Pump::connect: write error propagation + unix_open error code preservation (ENOENT, ECONNREFUSED, passthrough)
    const sockDir = fresh("pump");
    const liveSock = join(sockDir, "live.sock");
    const staleSock = join(sockDir, "stale.sock");
    const missingSock = join(sockDir, "missing.sock");
    const unixSrv = createServer();
    await new Promise<void>((r) => unixSrv.listen(liveSock, () => r()));
    linkSync(liveSock, staleSock);
    await new Promise<void>((r) => unixSrv.close(() => r()));
    const pumpRes = (await ask(door, "test.pumpConnectErrors", [missingSock, staleSock])).answer;
    assert.equal(pumpRes.writeErr, "Broken pipe", JSON.stringify(pumpRes));
    assert.equal(pumpRes.writeDestroyed, true, JSON.stringify(pumpRes));
    assert.equal(pumpRes.missingCode, "ENOENT", JSON.stringify(pumpRes));
    assert.equal(pumpRes.refusedCode, "ECONNREFUSED", JSON.stringify(pumpRes));
    assert.equal(pumpRes.otherCode, "Permission denied", JSON.stringify(pumpRes));

    // a device here, reached through another station's tunnel: what came with the ask first, then both ways
    const viewer = { workspace: "ws1", sub: "u1", email: "a@example.com", name: "A", role: "owner" };
    const added = await ask(door, "p54.route", ["POST", "/devices", viewer, JSON.stringify({ name: "echo", kind: "tcp", target: `${lan ?? "127.0.0.1"}:${echoPort}` })]);
    assert.equal(added.answer?.status, 200, JSON.stringify(added));
    const device = JSON.parse(added.answer.body).device;
    const listed = await ask(door, "p54.route", ["GET", "/devices", viewer, ""]);
    assert.deepEqual(JSON.parse(listed.answer.body).devices.map((x: any) => x.id), [device.id]);
    let heard = "";
    const tunnelEnd = createServer((s) => {
      s.write("more");
      s.on("data", (d) => {
        heard += d;
        if (heard.includes("echo:first") && heard.includes("more", heard.indexOf("echo:")) ) s.end();
      });
    });
    await new Promise<void>((r) => tunnelEnd.listen(0, "127.0.0.1", () => r()));
    const tunneledDevice = await ask(door, "test.hereDevice", ["ws1", device.id, (tunnelEnd.address() as any).port, "first"]);
    tunnelEnd.close();
    assert.deepEqual(tunneledDevice, { answer: true });
    assert.ok(heard.startsWith("echo:first"), heard);
    assert.match(heard, /echo:.*more/);
    assert.equal((await ask(door, "test.ioHeld")).answer, held, "the device's connection let go once the tunnel ended");
    const missing = await ask(door, "test.hereDevice", ["ws1", "0000000000000000", 1, ""]);
    assert.match(JSON.stringify(missing), /no such device/);

    // a tasks-only station's device as its rig reaches one (rig.mbt `reach`, devices/connect.ts `reachDevice`): the
    // device as its owner signed it opened, let go by `destroy`, its end told, and told again at once after it
    let rigClosed!: () => void;
    const rigGone = new Promise<void>((r) => (rigClosed = r));
    let rigReached = 0;
    const rigDevice = createServer((s) => {
      rigReached++;
      s.resume();
      s.on("close", () => rigClosed());
    });
    await new Promise<void>((r) => rigDevice.listen(0, "127.0.0.1", () => r()));
    const rigTarget = `127.0.0.1:${(rigDevice.address() as any).port}`;
    assert.deepEqual(await ask(door, "test.rigReach", [{ id: "0123456789abcdef", name: "rig echo", kind: "tcp", target: rigTarget }]), { answer: true });
    await rigGone;
    rigDevice.close();
    assert.equal(rigReached, 1);
    assert.equal((await ask(door, "test.ioHeld")).answer, held, "the rig's device connection let go");
    // a rig's device through a chat's tunnel (P5-1's `HereLocal` `device` on a rig: `Rig::device`'s socket carried
    // with the tunnel): what came with the ask first, then both ways, its end told the rig, nothing of it left
    let rigHeard = "";
    const rigTunnelEnd = createServer((s) => {
      s.write("more");
      s.on("data", (d) => {
        rigHeard += d;
        if (rigHeard.includes("echo:first") && rigHeard.includes("more", rigHeard.indexOf("echo:"))) s.end();
      });
    });
    await new Promise<void>((r) => rigTunnelEnd.listen(0, "127.0.0.1", () => r()));
    const rigEcho = { id: "0123456789abcdef", name: "rig echo", kind: "tcp", target: `${lan ?? "127.0.0.1"}:${echoPort}` };
    assert.deepEqual(await ask(door, "test.rigTunnel", [rigEcho, (rigTunnelEnd.address() as any).port, "first"]), { answer: true });
    rigTunnelEnd.close();
    assert.ok(rigHeard.startsWith("echo:first"), rigHeard);
    assert.match(rigHeard, /echo:.*more/);
    assert.equal((await ask(door, "test.ioHeld")).answer, held, "the rig's device and its tunnel let go once it ended");
    // a share's wait for the station taken out of its workspace: said as the control plane tells the removal, while
    // the station runs, its listener let go
    assert.deepEqual(await ask(door, "test.removedLater"), { answer: { waited: true, running: true, letGo: true } });

    // the browser's DevTools end: let go where the client is gone before its 101, and once where the gate terminates
    // it (terminated twice, then closed)
    const devtools = new WebSocketServer({ port: 0, host: "127.0.0.1" });
    await new Promise<void>((r) => devtools.on("listening", () => r()));
    let devtoolsOpened = 0;
    let devtoolsClosed = 0;
    let bothClosed!: () => void;
    const bothGone = new Promise<void>((r) => (bothClosed = r));
    devtools.on("connection", (s) => {
      devtoolsOpened++;
      s.on("close", () => {
        if (++devtoolsClosed === 2) bothClosed();
      });
    });
    const devtoolsUrl = `ws://127.0.0.1:${(devtools.address() as AddressInfo).port}/devtools/browser/test`;
    assert.deepEqual(await ask(door, "test.devtoolsUnanswered", [devtoolsUrl]), { answer: true });
    assert.deepEqual(await ask(door, "test.devtoolsEnded", [devtoolsUrl]), { answer: true });
    await bothGone;
    devtools.close();
    assert.deepEqual([devtoolsOpened, devtoolsClosed], [2, 2]);
    // a browser's process group whose leader ended while one of it goes on (Chrome's renderers): alive as a group,
    // ended by end_group
    assert.deepEqual(await ask(door, "test.groupLeftBehind"), { answer: { leader: false, group: true, after: false } });

    // the vault's backfills' one permit (store/backfill.ts) and its hold on the station's updating itself
    assert.deepEqual(await ask(door, "test.backfillPermit"), { answer: { first: true, second: false, givenBack: true, whileWriting: false, written: true, held: 1, after: 0 } });

    a.tell({ op: "stop" });
    assert.equal(await a.ended, 0);
  } finally {
    upstream.close();
    echo.close();
  }
});
