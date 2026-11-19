// The vault's service in MoonBit (station/mb src/vault_service, `stillfail-reader-harness --builder harness-vault-service`) held to
// the TypeScript it is the MoonBit of (src/vault/: secrets.ts, signin.ts, store.ts, plain.ts, tool.ts, run.ts, proxy.ts,
// ssh-agent.ts, x509.ts, scrub.ts, incoming.ts and their indexes), each run beside the other on a database of its own:
// the same clock, the same store (a fake hub of the test's, written again in the harness), the same browser, other
// stations and machine answered by the same fakes, the same requests in the same order. What each says (an answer, a
// refusal's words), what it tells (cards posted, withdrawn and restated, notices, events) and what it leaves in its
// database (every vault table, dumped) are compared, the ids, box keys and seals both make at random taken as names in
// the order each first shows them. The commands run with a grant are run for both (the program's by the machine this
// test gives it: Node's child_process and node:crypto, as run.ts, ssh-agent.ts and x509.ts use them).
import assert from "node:assert/strict";
import { type ChildProcess, type ChildProcessWithoutNullStreams, spawn } from "node:child_process";
import { X509Certificate, createHash, createPrivateKey, createPublicKey, generateKeyPairSync, sign as nodeSign, randomBytes } from "node:crypto";
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { mkdtempSync, rmSync } from "node:fs";
import { createServer, connect as netConnect, type Server, type Socket } from "node:net";
import { type IncomingMessage, createServer as createHttpServer } from "node:http";
import { request as httpsRequest } from "node:https";
import { type SecureContext, TLSSocket, createSecureContext } from "node:tls";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { DatabaseSync } from "node:sqlite";
import { after, test } from "node:test";
import { type Entry, type LockState, entryHash, genesis, signedBytes as lockBytes } from "../src/cloud/lock.ts";
import { endCommand, startCommand } from "../src/ops/processes.ts";
import { wall } from "../src/ops/fibers.ts";
import { mbHarnessBinary } from "./mb-harness.ts";
import { STILLFAIL_SURFACE } from "../src/store/store.ts";
import { type BoxCert, type Grant, type Item, type Request, type Sig, type Vault, TAG, encryptWith, grantContext, itemContext, keyContext, newBoxPair, seal, signedBytes } from "../src/vault/crypto.ts";
import { baseEnv } from "../src/vault/incoming.ts";
import { PlainStore, shown } from "../src/vault/plain.ts";
import { Proxy, placeholder, swap } from "../src/vault/proxy.ts";
import { createServer as createHttpsServer } from "node:https";
import { execFileSync } from "node:child_process";
import { capture } from "../src/vault/run.ts";
import { formsOf, scrub, Scrubber } from "../src/vault/scrub.ts";
import { Secrets, ulid } from "../src/vault/secrets.ts";
import { SignIns, siteOf } from "../src/vault/signin.ts";
import { answer as agentAnswer, parseSshKey } from "../src/vault/ssh-agent.ts";
import { VaultStore } from "../src/vault/store.ts";
import { vaultTools } from "../src/vault/tool.ts";
import { makeCa, makeLeaf, pem } from "../src/vault/x509.ts";
import { Incoming } from "../src/vault/incoming.ts";
import { withoutUseReader } from "./vault-no-reader.ts";
import { backfillNextWorkspace } from "../src/vault/use-index.ts";
import { backfillReboxIndex } from "../src/vault/rebox-index.ts";

const binary = mbHarnessBinary();
const skip = binary === null ? "the tests' MoonBit program (stillfail-reader-harness) is not built here" : false;

const WS = "01HZZZZZZZZZZZZZZZZZZZZZZZ";
const VAULT = "v_01HZZZZZZZZZZZZZZZZZZZZZZZ";
const T0 = 1_800_000_000_000;
const tick = () => new Promise((r) => setImmediate(r));
const settle = async (n = 20) => { for (let i = 0; i < n; i++) await tick(); };
/// What a side set going, waited for by the fact it comes to (each try a turn of the loop, or the program's answer);
/// never there, the test fails saying what.
const until = async (what: string, f: () => boolean | Promise<boolean>) => {
  for (let i = 0; i < 5000; i++) {
    if (await f()) return;
    await tick();
  }
  assert.fail(`never came: ${what}`);
};

const dirs: string[] = [];
const tmp = (prefix = "mb-vault-service-") => {
  const d = mkdtempSync(join(process.env.STILLFAIL_TEST_TMP ?? tmpdir(), prefix));
  dirs.push(d);
  return d;
};
const programs: Program[] = [];
const closers: (() => void | Promise<void>)[] = [];
// (the servers shut, then each program waited for till it is gone, its directories after: one still running at the
// file's end is a leftover)
after(async () => {
  await Promise.all(closers.map((c) => c()));
  await Promise.all(programs.map((p) => p.close()));
  for (const d of dirs) rmSync(d, { recursive: true, force: true });
});

/// A child let go: its stdin ended, and waited for until it is gone (killed 2 s after where it is not).
function ended(child: ChildProcess): Promise<void> {
  if (child.exitCode !== null || child.signalCode !== null) return Promise.resolve();
  const gone = new Promise<void>((r) => child.once("exit", () => r()));
  child.stdin?.end();
  setTimeout(() => child.kill("SIGKILL"), 2000).unref();
  return gone;
}

// ── the fake world both are given ──

type SessionRow = { ws: string | null; workspace: string; archivedAt?: number | null };
/// What the fake store holds: the test's, sent to the program as it changes (`state`).
type State = {
  home: string;
  sessions: Record<string, SessionRow>;
  starters: Record<string, string>;
  people: Record<string, string[]>;
  thread: { connect: string; thread: { id: number; channel: string; threadTs: string; surface: string } } | null;
  locks: Record<string, unknown>;
  peers: Record<string, { id: string; name: string } | string>;
  work: { dir: string };
  tabs: Record<string, { id: string; url: string }[]>;
};

/// The fake hub (harness.mbt `Harness::store` is the same): one thread, the cards posted in it, what it is told.
class FakeHub {
  cards: { text: string; card: unknown }[] = [];
  hidden = false;
  effects: unknown[] = [];
  readonly #state: () => State;
  constructor(state: () => State) {
    this.#state = state;
  }
  readonly store = {
    getSession: (k: string) => {
      const row = this.#state().sessions[k];
      return row === undefined ? null : { key: k, ws: row.ws, workspace: row.workspace, archivedAt: row.archivedAt ?? null };
    },
    starter: (k: string) => this.#state().starters[k] ?? null,
    participants: (k: string) => new Map([[k, this.#state().people[k] ?? []]]),
    latestThread: () => this.#state().thread,
    sessionThreadById: () => this.#state().thread,
    pendingCardHeader: (): [{ ts: string }, unknown] | null => this.hidden || this.cards.length === 0 ? null : [{ ts: String(this.cards.length) }, this.cards.at(-1)!.card],
    insertMessage: (m: { text: string; card: unknown }, before?: () => void) => {
      before?.();
      this.cards.push({ text: m.text, card: m.card });
      this.hidden = false;
      this.effects.push({ inserted: { text: m.text, card: m.card } });
      return [this.cards.length];
    },
    withdrawCard: (session: string, thread: number, ts: string) => (this.effects.push({ withdrawn: [session, thread, ts] }), true),
    restateCard: (session: string, thread: number, ts: string, f: (was: unknown) => unknown) => {
      const card = this.cards[Number(ts) - 1]?.card;
      this.effects.push({ restated: [session, thread, ts, f(card)] });
      return true;
    },
    subscribe: () => () => {},
  };
  chat = () => ({ post: async () => String(this.cards.length + 1) });
  shared = () => {};
  notify = (k: string, text: string) => void this.effects.push({ notified: [k, text] });
  take() {
    const e = this.effects;
    this.effects = [];
    return e;
  }
}

/// The lock as the program reads it (world.mbt `Lock::of_json`).
const lockJson = (lock: LockState) => ({
  ws: lock.ws,
  members: Object.fromEntries([...lock.members].map(([sub, m]) => [sub, { email: m.email }])),
  devices: Object.fromEntries([...lock.devices].map(([id, d]: [string, any]) => [id, { sub: d.sub, kind: d.kind, sign_key: d.sign_key, own: d.own }])),
  signKeys: Object.fromEntries(lock.signKeys ?? []),
});

// ── the machine the program is given (machine.mbt), as run.ts, ssh-agent.ts and x509.ts use Node ──

class Machine {
  readonly keys = new Map<string, ReturnType<typeof createPrivateKey>>();
  #next = 0;
  readonly servers = new Map<number, Server>();
  readonly contexts = new Map<string, SecureContext>();
  /// The roots a host's own certificate is checked against (a test's own upstream's).
  trust: string[] | undefined;
  /// The proxy as proxy.ts serves it, each CONNECT and each request decided by the program.
  proxyListen(p: Program, serve: number) {
    const HOP = ["proxy-authorization", "proxy-connection", "connection", "keep-alive", "te", "trailer", "transfer-encoding", "upgrade"];
    void HOP;
    const server = createHttpServer((_req, res) => res.writeHead(405, { "content-type": "text/plain" }).end("the vault's proxy carries HTTPS only (CONNECT)\n"));
    server.on("connect", async (req: IncomingMessage, socket: Socket, head: Buffer) => {
      socket.on("error", () => socket.destroy());
      const d = await p.fn("proxyConnect", [{ n: serve }, req.url ?? "", req.headers["proxy-authorization"] ?? null]);
      if (d.refuse) return void socket.end(d.refuse);
      if (d.tunnel) {
        const [host, port] = d.tunnel;
        const upstream = netConnect(port, host, () => {
          socket.write("HTTP/1.1 200 Connection Established\r\n\r\n");
          if (head.length > 0) upstream.write(head);
          upstream.pipe(socket);
          socket.pipe(upstream);
        });
        upstream.on("error", () => socket.end("HTTP/1.1 502 Bad Gateway\r\n\r\n"));
        socket.on("close", () => upstream.destroy());
        return;
      }
      const [host, port, context, run] = d.open;
      socket.write("HTTP/1.1 200 Connection Established\r\n\r\n");
      if (head.length > 0) socket.unshift(head);
      const tls = new TLSSocket(socket, { isServer: true, secureContext: this.contexts.get(context)!, ALPNProtocols: ["http/1.1"] });
      tls.on("error", () => tls.destroy());
      const inner = createHttpServer(async (r, res) => {
        const headers = Object.entries(r.headers).filter(([, v]) => v !== undefined).map(([k, v]) => [k, Array.isArray(v) ? v : [v!]]);
        const f = await p.fn("proxyForward", [{ n: serve }, { run, host, port, method: r.method, path: r.url, headers }]);
        if (f.forbid) return void res.writeHead(f.forbid[0]).end(f.forbid[1]);
        const out = httpsRequest({ host, port, servername: host, method: r.method, path: r.url, headers: Object.fromEntries(f.forward.map(([k, v]: [string, string[]]) => [k, v.length === 1 ? v[0] : v])), ...(this.trust ? { ca: this.trust } : {}) }, (answer) => {
          const back: Record<string, string | string[]> = {};
          for (const [name, value] of Object.entries(answer.headers)) if (value !== undefined && !["proxy-authorization", "proxy-connection", "connection", "keep-alive", "te", "trailer", "transfer-encoding", "upgrade"].includes(name)) back[name] = value;
          res.writeHead(answer.statusCode ?? 502, back);
          answer.pipe(res);
        });
        out.on("error", (e) => res.headersSent ? res.destroy() : res.writeHead(502).end(`the vault's proxy could not reach ${host}: ${e.message}\n`));
        r.pipe(out);
      });
      inner.on("clientError", (_e, s) => s.destroy());
      inner.emit("connection", tls);
    });
    closers.push(() => new Promise<void>((r) => { server.close(() => r()); server.closeAllConnections(); }));
    return new Promise((resolve, reject) => {
      server.once("error", reject);
      server.listen(0, "127.0.0.1", () => resolve({ port: (server.address() as { port: number }).port }));
    });
  }
  keyRef(key: ReturnType<typeof createPrivateKey>) {
    const handle = `k${++this.#next}`;
    this.keys.set(handle, key);
    const jwk = createPublicKey(key).export({ format: "jwk" });
    const b = (s: string) => Buffer.from(s, "base64url").toString("hex");
    const pub = jwk.kty === "EC" ? ["04" + b(jwk.x!) + b(jwk.y!)] : jwk.kty === "OKP" ? [b(jwk.x!)] : [b(jwk.e!), b(jwk.n!)];
    return { handle, kind: jwk.kty === "EC" ? "p256" : jwk.kty === "OKP" ? "ed25519" : "rsa", public: pub };
  }
  async call(p: Program, n: number, name: string, args: any[]): Promise<unknown> {
    switch (name) {
      case "machine.tempDir": return mkdtemp(join(tmpdir(), args[0]));
      case "machine.remove": return rm(args[0], { recursive: true, force: true }).then(() => null);
      case "machine.chmod": return chmod(args[0], args[1]).then(() => null);
      case "machine.writeFile": return writeFile(args[0], Buffer.from(args[1], "hex"), { mode: args[2] }).then(() => null);
      case "machine.readFile": return readFile(args[0]).then((b) => b.toString("hex"), () => null);
      case "machine.mkdir": return mkdir(args[0], { recursive: true, mode: args[1] }).then(() => null);
      case "machine.shellFor": return "/bin/sh";
      case "machine.spawn": return this.spawn(p, n, args as never);
      case "machine.p256New": return this.keyRef(generateKeyPairSync("ec", { namedCurve: "P-256" }).privateKey);
      case "machine.keyOfPem": try { return this.keyRef(createPrivateKey(args[0])); } catch { return null; }
      case "machine.ed25519OfSeed": return this.keyRef(createPrivateKey({ key: Buffer.concat([Buffer.from("302e020100300506032b657004220420", "hex"), Buffer.from(args[0], "hex")]), format: "der", type: "pkcs8" }));
      case "machine.rsaOfJwk": {
        const j = args[0];
        const big = (s: string) => BigInt(`0x${Buffer.from(s, "base64url").toString("hex") || "0"}`);
        const unbig = (v: bigint) => { const h = v.toString(16); return Buffer.from(h.length % 2 ? `0${h}` : h, "hex").toString("base64url"); };
        const D = big(j.d);
        return this.keyRef(createPrivateKey({ key: { ...j, dp: unbig(D % (big(j.p) - 1n)), dq: unbig(D % (big(j.q) - 1n)) }, format: "jwk" }));
      }
      case "machine.keyPem": return this.keys.get(args[0].handle)!.export({ format: "pem", type: "pkcs8" });
      case "machine.sign": {
        const key = this.keys.get(args[0].handle)!;
        const data = Buffer.from(args[2], "hex");
        if (args[0].kind === "ed25519") return nodeSign(null, data, key).toString("hex");
        if (args[0].kind === "p256") return nodeSign("sha256", data, { key, dsaEncoding: "der" }).toString("hex");
        return nodeSign(args[1], data, key).toString("hex");
      }
      case "machine.sha1": return createHash("sha1").update(Buffer.from(args[0], "hex")).digest("hex");
      case "machine.roots": return [];
      case "machine.tlsContext": {
        const handle = `t${++this.#next}`;
        this.contexts.set(handle, createSecureContext({ key: args[0], cert: args[1] }));
        return handle;
      }
      case "machine.proxyListen": return this.proxyListen(p, args[0]);
      case "machine.unixServe": return this.unixServe(p, args[0], args[1]);
      case "machine.unixClose": { this.servers.get(args[0])?.close(); return null; }
    }
    throw new Error(`the machine has no ${name}`);
  }
  spawn(p: Program, n: number, [shell, args, cwd, env, timeoutMs]: [string, string[], string, [string, string][], number]) {
    return new Promise((resolve) => {
      let child: ChildProcess;
      try {
        child = startCommand(shell, args, { cwd, env: Object.fromEntries(env), stdio: ["ignore", "pipe", "pipe"] });
      } catch (e) {
        resolve({ error: `could not start ${shell}: ${(e as Error).message}` });
        return;
      }
      let timedOut = false;
      const stop = setTimeout(() => { timedOut = true; endCommand(child, "SIGKILL"); }, timeoutMs);
      child.stdout!.on("data", (b: Buffer) => p.send({ chunk: n, stream: "out", hex: b.toString("hex") }));
      child.stderr!.on("data", (b: Buffer) => p.send({ chunk: n, stream: "err", hex: b.toString("hex") }));
      child.on("error", (e) => { clearTimeout(stop); resolve({ error: `could not start ${shell}: ${e.message}` }); });
      child.on("close", (code, signal) => { clearTimeout(stop); resolve({ code, signal, timedOut }); });
    });
  }
  unixServe(p: Program, serve: number, path: string) {
    const server = createServer((socket) => {
      const conn = ++this.#next;
      socket.on("data", async (chunk: Buffer) => {
        const a = await p.fn("unixChunk", [{ n: serve }, { n: conn }, chunk.toString("hex")]);
        socket.write(Buffer.from(a.out, "hex"));
        if (a.destroy) socket.destroy();
      });
      socket.on("error", () => socket.destroy());
    });
    this.servers.set(serve, server);
    closers.push(() => new Promise<void>((r) => server.close(() => r())));
    return new Promise((resolve, reject) => { server.once("error", reject); server.listen(path, () => resolve(null)); });
  }
}

/// What the program is answered with for what it asks the test (`call`): the machine's, the browser's and the other
/// stations' fakes, the same as the TypeScript's.
type Answers = { [name: string]: (...args: any[]) => unknown };

/// The program, asked a line at a time.
class Program {
  readonly #p: ChildProcessWithoutNullStreams;
  readonly #waiting = new Map<number | string, { ok: (v: any) => void; no: (e: Error) => void }>();
  #next = 0;
  readonly machine = new Machine();
  answers: Answers = {};
  constructor(bin: string) {
    this.#p = spawn(bin, ["--builder", "harness-vault-service", "--shell-dir", tmp()], { stdio: ["pipe", "pipe", "pipe"] });
    programs.push(this);
    createInterface({ input: this.#p.stdout }).on("line", (line) => void this.#heard(JSON.parse(line)));
    this.#p.stderr.on("data", (d) => process.stderr.write(d));
    this.#p.on("exit", (code, signal) => {
      for (const w of this.#waiting.values()) w.no(new Error(`the program ended (${code ?? signal})`));
      this.#waiting.clear();
    });
  }
  async #heard(a: any) {
    if ("call" in a) {
      const n = a.call as number;
      try {
        const value = a.name.startsWith("machine.") ? await this.machine.call(this, n, a.name, a.args) : await this.answers[a.name]!(...a.args);
        this.send({ ret: n, value: value ?? null });
      } catch (e) {
        this.send({ ret: n, throw: { message: (e as Error).message } });
      }
      return;
    }
    const key = "ans" in a ? a.ans : "ready" in a ? "ready" : "stated" in a ? "stated" : "clocked" in a ? "clocked" : null;
    const w = this.#waiting.get(key);
    this.#waiting.delete(key);
    w?.ok(a);
  }
  send(o: unknown) {
    this.#p.stdin.write(JSON.stringify(o) + "\n");
  }
  #wait(key: number | string, o: unknown): Promise<any> {
    return new Promise((ok, no) => {
      this.#waiting.set(key, { ok, no });
      this.send(o);
    });
  }
  setup(o: unknown) { return this.#wait("ready", { setup: o }); }
  state(s: State) { return this.#wait("stated", { state: s }); }
  clock(ms: number) { return this.#wait("clocked", { clock: ms }); }
  /// A function's answer: `{value}` or `{error: {kind, message}}`, with what it told (`effects`).
  said(name: string, args: unknown[] = []): Promise<{ value?: any; error?: { kind: string; message: string }; effects: unknown[] }> {
    const id = ++this.#next;
    return this.#wait(id, { fn: { id, name, args } });
  }
  async fn(name: string, args: unknown[] = []): Promise<any> {
    const a = await this.said(name, args);
    if (a.error) throw new Error(a.error.message);
    return a.value;
  }
  close(): Promise<void> {
    return ended(this.#p);
  }
}

// ── names for what each makes at random ──

/// `v` with each id (r_, i_, n_, x_ and a ULID), box key and seal named by the order each first shows, so the two
/// sides' are compared by where they are.
function namer() {
  const names = new Map<string, string>();
  const name = (kind: string, s: string) => {
    if (!names.has(s)) names.set(s, `<${kind}${[...names.keys()].filter((k) => k.startsWith(kind) || true).length}>`);
    return names.get(s)!;
  };
  const text = (s: string): string => s
    .replace(/\b([rinx])_[0-9A-HJKMNP-TV-Z]{26}\b/g, (m) => name(m[0]!, m))
    .replace(/x25519:[0-9a-f]{64}/g, (m) => name("box", m))
    .replace(/http:\/\/run:[A-Za-z0-9_-]+@/g, "http://run:<token>@");
  const value = (v: unknown, key?: string): unknown => {
    if (typeof v === "string") {
      if ((key === "secret" || key === "wrapped" || key === "ct") && v.length > 40) return "<sealed>";
      // (a grant made for each side's own box, signed by the app)
      if (key === "sig" && /^[0-9a-f]{128}$/.test(v)) return "<sig>";
      if ((key === "body" || key === "detail") && (v.startsWith("{") || v.startsWith("["))) {
        try { return { json: value(JSON.parse(v)) }; } catch { /* as words */ }
      }
      return text(v);
    }
    if (Array.isArray(v)) return v.map((x) => value(x));
    if (v !== null && typeof v === "object") return Object.fromEntries(Object.entries(v).map(([k, x]) => [text(k), value(x, k)]));
    return v;
  };
  return value;
}

/// Every table of the vault's, its rows in their key's order.
function dump(path: string) {
  const db = new DatabaseSync(path);
  try {
    // (the older sign-ins' save queue is its builder's process's, held by test/mb-signin-save.test.ts)
    const tables = (db.prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND (name LIKE 'vault%' OR name LIKE 'signin%') AND name NOT IN ('signin_save_pending', 'signin_save_progress') ORDER BY name").all() as { name: string }[]).map((r) => r.name);
    const out: Record<string, unknown[]> = {};
    // (where a background batch's cursor stopped is when it ran, the reader's own pace: what it came to is compared)
    for (const t of tables) out[t] = db.prepare(`SELECT * FROM ${t} ORDER BY 1, 2`).all().map((r) => "after_id" in r || "after_ws" in r ? { ...r, ...("after_id" in r ? { after_id: "<cursor>" } : {}), ...("after_ws" in r ? { after_ws: "<cursor>" } : {}) } : { ...r });
    out.schema = db.prepare("SELECT type, name, tbl_name, sql FROM sqlite_master WHERE name LIKE 'vault%' OR name LIKE 'signin%' ORDER BY name").all().map((r) => ({ ...r }));
    return out;
  } finally {
    db.close();
  }
}

// ── the two sides ──

/// The TypeScript and the program on databases of their own, given the same world.
async function pair(o: { env?: [string, string][]; trust?: string[]; start?: number; from?: { tsPath: string; mbPath: string; data: string; dir: string; now: number } } = {}) {
  const dir = o.from?.dir ?? tmp();
  const data = o.from?.data ?? tmp();
  const work = tmp();
  let now = o.from?.now ?? o.start ?? T0;
  const state: State = {
    home: WS,
    sessions: { s1: { ws: null, workspace: dir } },
    starters: { s1: "alice@x.com" },
    people: { s1: ["alice@x.com"] },
    thread: { connect: "c", thread: { id: 1, channel: "CHAT", threadTs: "1.0", surface: STILLFAIL_SURFACE } },
    locks: {},
    peers: {},
    work: { dir: work },
    tabs: {},
  };
  let locks: Record<string, LockState> = {};
  const lockOf = (ws: string | null) => locks[ws === null || ws === WS ? "" : ws] ?? null;
  const hub = new FakeHub(() => state);
  const told: unknown[] = [];
  const env = o.env ?? [["PATH", process.env.PATH ?? "/usr/bin:/bin"], ["HOME", process.env.HOME ?? "/tmp"]];
  const saved = Object.fromEntries(Object.entries(process.env));
  // The TypeScript reads the station's environment from process.env: it is the program's too.
  const tsDb = new DatabaseSync(o.from?.tsPath ?? join(tmp(), "ts.db"));
  const mbPath = o.from?.mbPath ?? join(tmp(), "mb.db");
  const vaults = new VaultStore(tsDb);
  const plain = new PlainStore(tsDb);
  // The other stations and the browser, answered alike for both.
  const asked: { ts: unknown[]; mb: unknown[] } = { ts: [], mb: [] };
  const elsewhere = (side: "ts" | "mb") => async (station: string, request: any) => {
    asked[side].push([station, request]);
    if (request.method === "vault.capabilities") return { timeouts: true };
    if (request.method === "vault.revoke") return { ok: true };
    return { started: true };
  };
  const browserLog: { ts: unknown[]; mb: unknown[] } = { ts: [], mb: [] };
  const browser = { jar: "[]" };
  const browsersFor = (side: "ts" | "mb") => ({
    cookies: async (session: string, sites: string[], station: boolean) => (browserLog[side].push(["cookies", session, sites, station]), browser.jar),
    signIn: async (session: string, d: unknown) => void browserLog[side].push(["signIn", session, d]),
    passkeysIn: async (session: string, d: unknown) => void browserLog[side].push(["passkeysIn", session, d]),
    extendSignIn: (session: string, request: string, until: number) => void hub.effects.push({ extended: [session, request, until] }),
  });
  const forms = { look: { username: true, password: true, code: false } as unknown, drives: [] as unknown[] };
  const driveFor = (side: "ts" | "mb") => async (session: string, tab: string, site: string, values: unknown, used: Set<string>) => {
    browserLog[side].push(["drive", session, tab, site, values, [...used]]);
    const a = (forms.drives.shift() ?? { state: "left" }) as { state: string };
    for (const k of ["username", "password", "code"]) if ((values as any)[k] !== undefined && a.state !== "person") used.add(k);
    return a;
  };
  const secrets = new Secrets({
    ...(o.trust ? { proxy: new Proxy(`${data}/vault`, () => now, o.trust) } : {}),
    db: withoutUseReader(tsDb), vaults, plain, home: () => state.home, hub: hub as never, data, lock: lockOf, now: () => now,
    peer: (given) => {
      const p = state.peers[given];
      if (typeof p === "string") throw new Error(p);
      return p ?? null;
    },
    ask: elsewhere("ts") as never,
    workOf: (ws, peer, session) => `${work}/${ws}/${peer}/${session}`,
    browsers: browsersFor("ts"),
  });
  const signIns = new SignIns({
    // (the older sign-ins' save index is a builder's process of its own: test/mb-signin-save.test.ts holds it)
    db: withoutUseReader(tsDb), hub: hub as never, now: () => now, after: () => () => {},
    workspace: (session) => state.sessions[session]?.ws ?? state.home,
    screenLink: () => null,
    id: () => `g_${now}`,
    browser: {
      tabs: (session) => state.tabs[session] ?? [],
      look: async () => forms.look as never,
      drive: driveFor("ts") as never,
    },
    vault: {
      listed: (session, site) => secrets.listings(session).find((l) => l.listing.kind === "browser" && (l.listing.hosts.includes(site)))?.item ?? null,
      held: () => null,
      use: (session, item, reason) => secrets.ask(session, { item, mode: "browser", reason }),
      keep: (session, site, reason, made, named) => {
        const on = secrets.status(session);
        return secrets.save(session, { name: named?.name ?? `${site} 登录态`, ...(named?.about ? { about: named.about } : {}), kind: "browser", hosts: [site], reason, cwd: "", ...(on === "on" || on === "plain" ? { quiet: made } : {}) });
      },
    },
  });
  closers.push(() => { secrets.proxy.close(); void secrets.close(); void signIns.close(); });
  secrets.listen((r) => signIns.heard(r));
  secrets.onPlainWritten((i) => hub.effects.push({ told: ["vault-plain", shown(i), `vault-plain\0${i.id}`, { workspace: i.ws, email: i.owner }] }));
  secrets.listen((r) => {
    const to = secrets.tells(r);
    if (to !== null) hub.effects.push({ told: ["vault-request", JSON.parse(JSON.stringify(r)), `vault-request\0${r.id}`, to] });
  });
  secrets.reboxed();
  hub.effects.push({ passkeysAgainAll: null });

  const mb = new Program(binary!);
  mb.machine.trust = o.trust;
  mb.answers = {
    ask: elsewhere("mb"),
    "browser.cookies": browsersFor("mb").cookies,
    "browser.signIn": browsersFor("mb").signIn,
    "browser.passkeysIn": browsersFor("mb").passkeysIn,
    "browser.look": async () => forms.look,
    "browser.drive": async (session: string, tab: string, site: string, values: unknown, used: string[]) => {
      const set = new Set(used);
      const driven = await driveFor("mb")(session, tab, site, values, set);
      return { driven, used: [...set] };
    },
  };
  const sync = async () => {
    state.locks = Object.fromEntries(Object.entries(locks).map(([k, l]) => [k, lockJson(l)]));
    await mb.state(state);
  };
  await sync();
  await mb.clock(now);
  const ready = await mb.setup({ db: mbPath, data, env });
  assert.equal(ready.ready, true, ready.error);
  const mbSetupEffects = ready.effects;
  const tsSetupEffects = [...hub.take(), ...told.splice(0)];
  assert.deepEqual(mbSetupEffects, tsSetupEffects);

  /// The TypeScript's answer as the program's is said: a value or a refusal's words, with what it told.
  const ts = async (f: () => unknown) => {
    let out: { value?: unknown; error?: { kind: string; message: string } };
    try {
      // (a function that answers nothing answers null, as the program says it)
      out = { value: (await f()) ?? null };
    } catch (e) {
      out = { error: { kind: (e as Error).name === "AbortError" ? "AbortError" : (e as Error).constructor.name === "Refused" ? "Refused" : "Error", message: (e as Error).message } };
    }
    for (const x of told.splice(0)) hub.effects.push(x);
    return { ...out, effects: hub.take() };
  };
  /// Both asked the same: their answers, named, the same.
  const both = async (what: string, tsDo: () => unknown, name: string, args: unknown[], shape: (v: any) => unknown = (v) => v) => {
    const t = await ts(tsDo);
    const m = await mb.said(name, args);
    const n1 = namer(), n2 = namer();
    const a = { ...t, value: t.value === undefined ? undefined : n1(shape(JSON.parse(JSON.stringify(t.value ?? null)))), error: n1(t.error), effects: n1(t.effects) };
    const { ans: _, ...mm } = m as typeof m & { ans?: unknown };
    const b = { ...mm, value: m.value === undefined ? undefined : n2(shape(m.value)), error: n2(m.error), effects: n2(m.effects) };
    assert.deepEqual(b, a, what);
    return { ts: t, mb: m };
  };
  const compareDbs = async (what: string) => {
    // (the use reader's background run to its end on both: what each station's reader comes to)
    while (!backfillReboxIndex(tsDb));
    while (!backfillNextWorkspace(tsDb));
    await mb.fn("drain");
    const a = namer()(dump(tsDb.location()!)), b = namer()(dump(mbPath));
    assert.deepEqual(b, a, what);
  };
  return {
    state, sync, hub, secrets, signIns, tsDb, mbPath, mb, both, ts, vaults, plain, browser, forms, browserLog, asked, compareDbs, dir, data,
    setLock: async (ws: string, l: LockState | null) => { if (l === null) delete locks[ws]; else locks[ws] = l; await sync(); },
    at: async (ms: number) => { now = ms; await mb.clock(ms); },
    now: () => now,
    restoreEnv: () => { for (const k of Object.keys(process.env)) if (!(k in saved)) delete process.env[k]; Object.assign(process.env, saved); },
  };
}

// ── a lock and its vault, as vault-save.test.ts makes them ──

function ed() {
  const key = generateKeyPairSync("ed25519").privateKey;
  const hex = Buffer.from(createPublicKey(key).export({ format: "jwk" }).x as string, "base64url").toString("hex");
  return { hex, id: `ed25519:${hex}`, sign: (bytes: Buffer) => nodeSign(null, bytes, key).toString("hex") };
}
type Key = ReturnType<typeof ed>;
type Person = { sub: string; signer: Key; base: Key; box: { pub: string; priv: Uint8Array } };
const fill = (b: number, n = 32) => new Uint8Array(n).fill(b);
function signed<T extends Record<string, unknown>>(o: T, tag: string, key: Key): T & { sig: Sig } {
  return { ...o, sig: { key: key.id, alg: "Ed25519", sig: key.sign(signedBytes(o, tag)) } };
}
function lockWorld() {
  const [alice, bob] = ["alice", "bob"].map((sub) => ({ sub, signer: ed(), base: ed(), box: newBoxPair() })) as [Person, Person];
  const body = {
    owner: "alice", origins: ["https://app.still.fail"], rp_id: "app.still.fail", cloud_keys: { keys: [] },
    members: [{ sub: "alice", email: "alice@x.com", role: "owner" }, { sub: "bob", email: "bob@x.com", role: "member" }],
    devices: [alice, bob].map((p) => ({ id: p.base.hex, sub: p.sub, kind: "app", label: p.sub, sign_key: p.signer.id })),
    passkeys: [], stations: [], gateways: [],
  };
  const e = { v: 1, ws: WS, seq: 0, prev: null, at: 1000, kind: "genesis", body } as Omit<Entry, "sig">;
  const state = genesis({ ...e, sig: { key: alice.signer.id, alg: "Ed25519" as const, sig: alice.signer.sign(lockBytes(entryHash(e as Entry))) } });
  const cert = (p: Person): BoxCert => signed({ v: 1 as const, ws: WS, device: p.base.hex, box: p.box.pub, at: 1000 }, TAG.box, p.signer);
  const vault: Vault = signed(
    { v: 1 as const, ws: WS, id: VAULT, seq: 0, owner: "alice", name: "Personal", members: ["alice", "bob"], epoch: 0, keys: [{ cert: cert(alice), wrapped: seal(alice.box.pub, fill(4), keyContext(WS, VAULT, 0)) }], at: 1000 },
    TAG.vault, alice.signer,
  );
  const plainOf = (fields: Record<string, string>, kind = "token", name = "GitHub") => ({ kind, name, fields, domains: [], notes: "" });
  const item = (id: string, listing: Item["listing"], fields: Record<string, string>, by: Person = alice, kind = "token"): Item => signed(
    { v: 1 as const, ws: WS, vault: VAULT, id, version: 0, epoch: 0, ct: encryptWith(fill(4), Buffer.from(JSON.stringify(plainOf(fields, kind, listing!.name))), itemContext(WS, VAULT, id, 0, 0), fill(5, 12)), listing, at: 1000 },
    TAG.item, by.signer,
  );
  /// The grant `by`'s app sends for request `r` (sealed to its box: each side's own).
  const grant = (r: Request, fields: Record<string, string>, scope: Grant["scope"], by: Person = alice, kind = "token", name = "GitHub"): Grant => signed(
    { v: 1 as const, ws: WS, request: r.id, vault: r.vault, item: r.item, mode: r.mode, hosts: r.hosts ?? [], scope, exp: Math.floor(T0 / 1000) + 3000, ...(r.timeout && scope !== "once" ? { timeout: r.timeout } : {}),
      secret: seal(r.box, Buffer.from(JSON.stringify(plainOf(fields, kind, name))), grantContext(WS, r.id)), at: Math.floor(T0 / 1000) },
    TAG.grant, by.signer,
  );
  const deny = (r: Request, by: Person = alice) => signed({ v: 1 as const, ws: WS, request: r.id, at: Math.floor(T0 / 1000) }, TAG.deny, by.signer);
  return { alice, bob, state, cert, vault, item, grant, deny };
}

/// Both stores given the same vault rows (what members' apps brought).
function putBoth(p: Awaited<ReturnType<typeof pair>>, f: (v: VaultStore) => void) {
  f(p.vaults);
  const db = new DatabaseSync(p.mbPath);
  try { f(new VaultStore(db)); } finally { db.close(); }
}

// ── the cases ──

test("the tools: the same names, descriptions and parameters as the agents are told", { skip }, async () => {
  const p = await pair();
  const tools = vaultTools(p.secrets, () => p.dir, p.signIns).map((t) => ({ name: t.name, description: t.description, inputSchema: t.inputSchema }));
  assert.deepEqual(await p.mb.fn("tools"), JSON.parse(JSON.stringify(tools)));
});

test("the plain library: kept, listed, asked for, granted, run with, renamed, deleted, refused, withdrawn, asked again", { skip }, async () => {
  const p = await pair();
  const s = p.secrets;
  await p.both("status", () => s.status("s1"), "status", ["s1"]);
  await p.both("no listings", () => s.listings("s1"), "listings", ["s1"]);
  await p.both("a stranger named", () => s.listings("s1", "eve@x.com"), "listings", ["s1", "eve@x.com"]);
  const save = { name: "GitHub token", kind: "token", reason: "推送 PR", value: "ghp_secret_value_1234", hosts: ["api.github.com"], env: "GH_TOKEN", about: "the bot's token", cwd: p.dir };
  const kept = await p.both("save", () => s.save("s1", save), "save", ["s1", save]);
  const rid = (v: unknown) => { const m = /r_[0-9A-Z]{26}/.exec(String(v)); if (m === null) throw new Error(`no request in: ${JSON.stringify(v)}`); return m[0]; };
  const [tsSave, mbSave] = [rid(kept.ts.value ?? kept.ts.error), rid(kept.mb.value)];
  for (const bad of [{ ...save, kind: "nope" }, { ...save, name: " " }, { ...save, reason: "" }, { ...save, value: undefined, command: undefined, kind: "browser", hosts: [] }, { ...save, modes: ["ssh"] }, { ...save, path: "/x" }, { ...save, oauth: "slack" }, { ...save, about: "x".repeat(2001) }])
    await p.both(`a save refused: ${JSON.stringify(bad).slice(0, 80)}`, () => s.save("s1", bad as never), "save", ["s1", bad]);
  await p.both("pending", () => s.pending(WS, null, { sub: "alice", email: "alice@x.com" }), "pending", [WS, "alice", "alice@x.com"]);
  await p.both("not theirs", () => s.savedPlain(WS, null, "bob@x.com", { request: tsSave }), "savedPlain", [WS, "bob@x.com", { request: mbSave }]);
  await p.both("kept", () => s.savedPlain(WS, null, "alice@x.com", { request: tsSave }), "savedPlain", [WS, "alice@x.com", { request: mbSave }]);
  await p.both("kept again", () => s.savedPlain(WS, null, "alice@x.com", { request: tsSave }), "savedPlain", [WS, "alice@x.com", { request: mbSave }]);
  await p.both("its grant", () => s.held("s1"), "held", ["s1"]);
  await p.both("listed", () => s.listings("s1"), "listings", ["s1"]);
  await p.both("tool secret_list", () => vaultTools(s, () => p.dir, p.signIns).find((t) => t.name === "secret_list")!.run("s1", {}), "tool", ["secret_list", "s1", {}]);
  // asked for, granted for an hour, run with
  await p.at(T0 + 1000);
  const use = { item: "github token", reason: "重跑 CI", command: "gh run rerun 1", mode: "env" };
  await p.both("a mode it is not given by", () => s.ask("s1", use), "ask", ["s1", use]);
  const use2 = { ...use, mode: "proxy" };
  const asked = await p.both("asked", () => s.ask("s1", use2), "ask", ["s1", use2]);
  const [tsUse, mbUse] = [rid(asked.ts.value ?? asked.ts.error), rid(asked.mb.value)];
  for (const bad of [{ ...use2, item: "nothing" }, { ...use2, reason: " " }, { ...use2, timeout: { kind: "idle", seconds: 61 } }])
    await p.both(`an ask refused: ${bad.item}`, () => s.ask("s1", bad as never), "ask", ["s1", bad]);
  await p.both("the use's card again (it is there)", () => s.reask("s1", tsUse), "reask", ["s1", mbUse]);
  p.hub.hidden = true;
  await p.mb.said("hideCard");
  await p.both("its card again", () => s.reask("s1", tsUse), "reask", ["s1", mbUse]);
  const grant = { scope: "hour", timeout: { kind: "idle", seconds: 3600 } };
  await p.both("granted", () => s.grantPlain(WS, null, "alice@x.com", { request: tsUse, ...grant }), "grantPlain", [WS, "alice@x.com", { request: mbUse, ...grant }]);
  await p.both("granted twice", () => s.grantPlain(WS, null, "alice@x.com", { request: tsUse, ...grant }), "grantPlain", [WS, "alice@x.com", { request: mbUse, ...grant }]);
  await p.both("held", () => s.held("s1"), "held", ["s1"]);
  const command = `printf 'token=%s\\n' "$GH_TOKEN"; printf '%s' "$STILLFAIL_SECRET" | head -c 18; echo; echo "$HTTPS_PROXY" | cut -c1-11`;
  // (the proxy's mode: its port is each side's own, its token named)
  await p.both("run through the proxy", () => s.run("s1", { grant: tsUse, command: "printf '%s\\n' \"$GH_TOKEN\"", cwd: p.dir }), "run", ["s1", { grant: mbUse, command: "printf '%s\\n' \"$GH_TOKEN\"", cwd: p.dir }]);
  void command;
  await p.both("run with no such grant", () => s.run("s1", { grant: "r_nothing", command: "true", cwd: p.dir }), "run", ["s1", { grant: "r_nothing", command: "true", cwd: p.dir }]);
  await p.both("a bad variable", () => s.run("s1", { grant: tsUse, command: "true", env: "1X", cwd: p.dir }), "run", ["s1", { grant: mbUse, command: "true", env: "1X", cwd: p.dir }]);
  // an env grant whose command prints the secret: hidden
  const use3 = { item: "github token", reason: "看看", mode: "env" };
  // (the item is given by proxy alone: refused)
  await p.both("env refused", () => s.ask("s1", use3), "ask", ["s1", use3]);
  // renamed, refused, withdrawn
  await p.at(T0 + 2000);
  const describe = { item: "GitHub token", name: "GitHub bot token", about: "", reason: "名字更清楚" };
  const d = await p.both("describe", () => s.describe("s1", describe), "describe", ["s1", describe]);
  await p.both("described", () => s.describedPlain(WS, null, "alice@x.com", { request: rid(d.ts.value ?? d.ts.error) }), "describedPlain", [WS, "alice@x.com", { request: rid(d.mb.value) }]);
  await p.both("described twice", () => s.describedPlain(WS, null, "alice@x.com", { request: rid(d.ts.value ?? d.ts.error) }), "describedPlain", [WS, "alice@x.com", { request: rid(d.mb.value) }]);
  await p.both("nothing to change", () => s.describe("s1", { item: "GitHub bot token", name: "GitHub bot token", about: "", reason: "x" }), "describe", ["s1", { item: "GitHub bot token", name: "GitHub bot token", about: "", reason: "x" }]);
  await p.at(T0 + 3000);
  use2.item = "github bot token";
  const a2 = await p.both("asked again", () => s.ask("s1", use2), "ask", ["s1", use2]);
  await p.both("refused", () => s.denyPlain(WS, "alice@x.com", { request: rid(a2.ts.value ?? a2.ts.error) }), "denyPlain", [WS, "alice@x.com", { request: rid(a2.mb.value) }]);
  await p.at(T0 + 4000);
  const a3 = await p.both("asked a third time", () => s.ask("s1", use2), "ask", ["s1", use2]);
  await p.both("withdrawn", () => s.cancel("s1", rid(a3.ts.value ?? a3.ts.error)), "cancel", ["s1", rid(a3.mb.value)]);
  await p.both("withdrawn twice", () => s.cancel("s1", rid(a3.ts.value ?? a3.ts.error)), "cancel", ["s1", rid(a3.mb.value)]);
  await p.both("withdrawn: no such", () => s.cancel("s1", "r_nope"), "cancel", ["s1", "r_nope"]);
  // the uses, the audit, what goes over at a handover
  await p.both("uses", () => s.uses(WS, null, "plain", { sub: "alice", email: "alice@x.com" }), "uses", [WS, "plain", "alice", "alice@x.com"]);
  await p.both("audit", () => s.audit(WS, "plain"), "audit", [WS, "plain"]);
  await p.both("carried", () => s.carried(), "carried", []);
  await p.both("tells", () => s.tells({ ws: WS, vault: "plain", owner: "alice@x.com" } as never), "tells", [{ ws: WS, vault: "plain", owner: "alice@x.com" }]);
  // deleted
  await p.at(T0 + 5000);
  const rm = { item: "GitHub bot token", reason: "不用了" };
  const r = await p.both("remove", () => s.remove("s1", rm), "remove", ["s1", rm]);
  await p.both("removed", () => s.removedPlain(WS, "alice@x.com", { request: rid(r.ts.value ?? r.ts.error) }), "removedPlain", [WS, "alice@x.com", { request: rid(r.mb.value) }]);
  await p.both("listed: none", () => s.listings("s1"), "listings", ["s1"]);
  await p.compareDbs("the databases");
});

test("a command run with a grant: its output with the secret hidden, a file written for it, a capture", { skip }, async () => {
  const p = await pair();
  const s = p.secrets;
  const rid = (v: unknown) => { const m = /r_[0-9A-Z]{26}/.exec(String(v)); if (m === null) throw new Error(`no request in: ${JSON.stringify(v)}`); return m[0]; };
  const save = { name: "DB password", kind: "login", username: "admin", reason: "连数据库", value: "pa:ss/wo+rd=1234", modes: ["env"], about: "the db", cwd: p.dir };
  const k = await p.both("save", () => s.save("s1", save), "save", ["s1", save]);
  await p.both("kept", () => s.savedPlain(WS, null, "alice@x.com", { request: rid(k.ts.value ?? k.ts.error) }), "savedPlain", [WS, "alice@x.com", { request: rid(k.mb.value) }]);
  await p.at(T0 + 1000);
  const use = { item: "DB password", reason: "查数据", command: "psql" };
  const a = await p.both("asked", () => s.ask("s1", use), "ask", ["s1", use]);
  await p.both("granted once", () => s.grantPlain(WS, null, "alice@x.com", { request: rid(a.ts.value ?? a.ts.error), scope: "once" }), "grantPlain", [WS, "alice@x.com", { request: rid(a.mb.value), scope: "once" }]);
  const command = `printf 'pw=%s user=%s\\n' "$STILLFAIL_SECRET" "$STILLFAIL_USERNAME"; printf '%s' "$STILLFAIL_SECRET" | base64; echo err >&2; exit 3`;
  await p.both("run once", () => s.run("s1", { grant: rid(a.ts.value ?? a.ts.error), command, cwd: p.dir }), "run", ["s1", { grant: rid(a.mb.value), command, cwd: p.dir }]);
  await p.both("spent", () => s.run("s1", { grant: rid(a.ts.value ?? a.ts.error), command, cwd: p.dir }), "run", ["s1", { grant: rid(a.mb.value), command, cwd: p.dir }]);
  // a file kept and given as a file
  await p.at(T0 + 2000);
  const file = { name: "kubeconfig", kind: "file", reason: "部署", value: "apiVersion: v1\nkind: Config\n", filename: "config", about: "the cluster", cwd: p.dir };
  const f = await p.both("a file", () => s.save("s1", file), "save", ["s1", file]);
  await p.both("kept", () => s.savedPlain(WS, null, "alice@x.com", { request: rid(f.ts.value ?? f.ts.error) }), "savedPlain", [WS, "alice@x.com", { request: rid(f.mb.value) }]);
  // (kept by a save: this chat may use it, an hour)
  const fileCommand = `basename "$STILLFAIL_SECRET"; cat "$STILLFAIL_SECRET"; ls -l "$STILLFAIL_SECRET" | cut -c1-10`;
  await p.both("run with the file", () => s.run("s1", { grant: rid(f.ts.value ?? f.ts.error), command: fileCommand, cwd: p.dir }), "run", ["s1", { grant: rid(f.mb.value), command: fileCommand, cwd: p.dir }]);
  // printed by a command
  await p.at(T0 + 3000);
  const printed = { name: "printed", kind: "token", reason: "存", command: "printf 'tok-123456789\\n'; echo noise >&2", about: "printed", cwd: p.dir };
  await p.both("printed", () => s.save("s1", printed), "save", ["s1", printed]);
  const failed = { ...printed, command: "echo oops >&2; exit 2" };
  await p.both("a command that fails", () => s.save("s1", failed), "save", ["s1", failed]);
  const big = { ...printed, command: "head -c 70000 /dev/zero | tr '\\0' a" };
  await p.both("printed too much", () => s.save("s1", big), "save", ["s1", big]);
  await p.both("capture", () => capture("printf 'x-secret\\n'; echo 'x-secret on err' >&2", p.dir, baseEnv(), 5000), "capture", ["printf 'x-secret\\n'; echo 'x-secret on err' >&2", p.dir, { ms: 5000 }]);
  await p.compareDbs("the databases");
});

test("a vault: kept by an app, sealed to a device published later, asked for, granted, refused, renamed and deleted", { skip }, async () => {
  const p = await pair();
  const s = p.secrets;
  const w = lockWorld();
  await p.setLock("", w.state);
  putBoth(p, (v) => { v.putBox(w.cert(w.alice)); v.putVault(w.vault); });
  const rid = (v: unknown) => { const m = /r_[0-9A-Z]{26}/.exec(String(v)); if (m === null) throw new Error(`no request in: ${JSON.stringify(v)}`); return m[0]; };
  await p.both("status", () => s.status("s1"), "status", ["s1"]);
  await p.both("status of bob", () => s.status("s1", "bob@x.com"), "status", ["s1", "bob@x.com"]);
  const save = { name: "Deploy key", kind: "token", reason: "部署", value: "dk_0123456789abcdef", hosts: ["api.fly.io"], about: "fly", cwd: p.dir };
  const k = await p.both("save", () => s.save("s1", save), "save", ["s1", save]);
  const [tsSave, mbSave] = [rid(k.ts.value ?? k.ts.error), rid(k.mb.value)];
  // bob's device published: nothing of alice's sealed to it; alice's second (none here), the same request
  await p.both("boxed (bob)", () => s.boxed(w.state, w.cert(w.bob)), "boxed", [WS, w.cert(w.bob)]);
  await p.both("pending (alice)", () => s.pending(WS, w.state, { sub: "alice", email: "alice@x.com" }), "pending", [WS, "alice", "alice@x.com"]);
  // her app writes the item into her vault, then says so
  const tsReq = JSON.parse((p.tsDb.prepare("SELECT body FROM vault_requests WHERE id = ?").get(tsSave) as { body: string }).body) as Request;
  const mbDb = new DatabaseSync(p.mbPath);
  const mbReq = JSON.parse((mbDb.prepare("SELECT body FROM vault_requests WHERE id = ?").get(mbSave) as { body: string }).body) as Request;
  mbDb.close();
  const listing = { name: "Deploy key", kind: "token" as const, modes: ["proxy" as const], hosts: ["api.fly.io"], about: "fly" };
  w.vault.members;
  p.vaults.putItem(w.item(tsReq.item, listing, { value: "dk_0123456789abcdef" }));
  { const db = new DatabaseSync(p.mbPath); new VaultStore(db).putItem(w.item(mbReq.item, listing, { value: "dk_0123456789abcdef" })); db.close(); }
  await p.both("saved by bob", () => s.saved(w.state, "bob", { request: tsSave, vault: VAULT }), "saved", [WS, "bob", { request: mbSave, vault: VAULT }]);
  await p.both("saved", () => s.saved(w.state, "alice", { request: tsSave, vault: VAULT, grant: w.grant(tsReq, { value: "dk_0123456789abcdef" }, "hour", w.alice, "token", "Deploy key") }), "saved", [WS, "alice", { request: mbSave, vault: VAULT, grant: w.grant(mbReq, { value: "dk_0123456789abcdef" }, "hour", w.alice, "token", "Deploy key") }]);
  await p.both("held", () => s.held("s1"), "held", ["s1"]);
  await p.both("listed", () => s.listings("s1"), "listings", ["s1"]);
  // another item of the vault, asked for by bob's chat
  await p.at(T0 + 1000);
  p.state.sessions.s2 = { ws: null, workspace: p.dir };
  p.state.starters.s2 = "bob@x.com";
  p.state.people.s2 = ["bob@x.com"];
  await p.sync();
  const shared = { name: "Shared API", kind: "token" as const, modes: ["env" as const, "proxy" as const], hosts: ["api.example.com"], env: "API_KEY" };
  putBoth(p, (v) => v.putItem(w.item("i_01HZZZZZZZZZZZZZZZZZZZZZZY", shared, { value: "shared-key-0000000" })));
  await p.both("bob's listings", () => s.listings("s2"), "listings", ["s2"]);
  const use = { item: "Shared API", reason: "调接口", command: "curl", timeout: { kind: "fixed" as const, seconds: 1800 } };
  const a = await p.both("asked", () => s.ask("s2", use), "ask", ["s2", use]);
  const reqOf = (path: string, id: string) => { const db = new DatabaseSync(path); try { return JSON.parse((db.prepare("SELECT body FROM vault_requests WHERE id = ?").get(id) as { body: string }).body) as Request; } finally { db.close(); } };
  const [tsUse, mbUse] = [rid(a.ts.value ?? a.ts.error), rid(a.mb.value)];
  const g = (path: string, id: string) => w.grant(reqOf(path, id), { value: "shared-key-0000000" }, "hour", w.alice, "token", "Shared API");
  await p.both("not a member's", () => s.grant(w.state, "carol", g(p.tsDb.location()!, tsUse)), "grant", [WS, "carol", g(p.mbPath, mbUse)]);
  await p.both("granted", () => s.grant(w.state, "alice", g(p.tsDb.location()!, tsUse)), "grant", [WS, "alice", g(p.mbPath, mbUse)]);
  await p.both("bob holds it", () => s.held("s2"), "held", ["s2"]);
  const command = `printf '[%s]\\n' "$API_KEY"; echo "$STILLFAIL_SECRET" | rev`;
  await p.both("run", () => s.run("s2", { grant: tsUse, command, cwd: p.dir }), "run", ["s2", { grant: mbUse, command, cwd: p.dir }]);
  await p.both("a chat's grant run by another", () => s.run("s1", { grant: tsUse, command, cwd: p.dir }), "run", ["s1", { grant: mbUse, command, cwd: p.dir }]);
  // refused by a device's signature
  await p.at(T0 + 2000);
  const b = await p.both("asked again", () => s.ask("s2", use), "ask", ["s2", use]);
  const deny = (path: string, id: string) => w.deny(reqOf(path, id));
  await p.both("refused unsigned", () => s.deny(w.state, "alice", { ...deny(p.tsDb.location()!, rid(b.ts.value ?? b.ts.error)), sig: { key: w.alice.signer.id, alg: "Ed25519", sig: "00" } }), "deny", [WS, "alice", { ...deny(p.mbPath, rid(b.mb.value)), sig: { key: w.alice.signer.id, alg: "Ed25519", sig: "00" } }]);
  await p.both("refused", () => s.deny(w.state, "alice", deny(p.tsDb.location()!, rid(b.ts.value ?? b.ts.error))), "deny", [WS, "alice", deny(p.mbPath, rid(b.mb.value))]);
  // renamed and deleted by the app
  await p.at(T0 + 3000);
  const describe = { item: "Shared API", name: "Example API", reason: "改名" };
  const d = await p.both("describe", () => s.describe("s2", describe), "describe", ["s2", describe]);
  await p.both("described too early", () => s.described(w.state, "alice", { request: rid(d.ts.value ?? d.ts.error) }), "described", [WS, "alice", { request: rid(d.mb.value) }]);
  putBoth(p, (v) => v.putItem({ ...w.item("i_01HZZZZZZZZZZZZZZZZZZZZZZY", { ...shared, name: "Example API" }, { value: "shared-key-0000000" }), version: 1 } as Item));
  await p.both("described", () => s.described(w.state, "alice", { request: rid(d.ts.value ?? d.ts.error) }), "described", [WS, "alice", { request: rid(d.mb.value) }]);
  await p.at(T0 + 4000);
  const r = await p.both("remove", () => s.remove("s2", { item: "Example API", reason: "删" }), "remove", ["s2", { item: "Example API", reason: "删" }]);
  await p.both("removed too early", () => s.removed(w.state, "alice", { request: rid(r.ts.value ?? r.ts.error) }), "removed", [WS, "alice", { request: rid(r.mb.value) }]);
  putBoth(p, (v) => v.putItem({ ...w.item("i_01HZZZZZZZZZZZZZZZZZZZZZZY", { ...shared, name: "Example API" }, { value: "x" }), version: 2, deleted: true } as Item));
  await p.both("removed", () => s.removed(w.state, "alice", { request: rid(r.ts.value ?? r.ts.error) }), "removed", [WS, "alice", { request: rid(r.mb.value) }]);
  await p.both("in the vault", () => s.inVault({ sub: "bob", workspace: WS }, VAULT), "inVault", ["bob", WS, VAULT]);
  await p.both("uses", () => s.uses(WS, w.state, VAULT, { sub: "alice", email: "alice@x.com" }), "uses", [WS, VAULT, "alice", "alice@x.com"]);
  p.state.sessions.s2!.archivedAt = 1;
  await p.sync();
  await p.both("chat archived", () => null, "sessionChanged", ["s2"]);
  await p.compareDbs("the databases");
});

test("a command on another station: sent there, ended by its word; asked of this one by another", { skip }, async () => {
  const p = await pair();
  const s = p.secrets;
  const rid = (v: unknown) => { const m = /r_[0-9A-Z]{26}/.exec(String(v)); if (m === null) throw new Error(`no request in: ${JSON.stringify(v)}`); return m[0]; };
  p.state.peers = { other: { id: "p1", name: "Other" }, gone: "no station gone in this workspace" };
  await p.sync();
  const save = { name: "Token", kind: "token", reason: "存", value: "tok_abcdefghij", about: "t", cwd: p.dir, modes: ["env"] };
  const k = await p.both("save", () => s.save("s1", save), "save", ["s1", save]);
  await p.both("kept", () => s.savedPlain(WS, null, "alice@x.com", { request: rid(k.ts.value ?? k.ts.error) }), "savedPlain", [WS, "alice@x.com", { request: rid(k.mb.value) }]);
  await p.at(T0 + 1000);
  await p.both("no such station", () => s.ask("s1", { item: "Token", reason: "r", station: "gone" }), "ask", ["s1", { item: "Token", reason: "r", station: "gone" }]);
  const a = await p.both("asked for another station", () => s.ask("s1", { item: "Token", reason: "r", station: "other" }), "ask", ["s1", { item: "Token", reason: "r", station: "other" }]);
  await p.both("granted", () => s.grantPlain(WS, null, "alice@x.com", { request: rid(a.ts.value ?? a.ts.error), scope: "hour", timeout: { kind: "idle", seconds: 3600 } }), "grantPlain", [WS, "alice@x.com", { request: rid(a.mb.value), scope: "hour", timeout: { kind: "idle", seconds: 3600 } }]);
  await p.both("run here: refused", () => s.run("s1", { grant: rid(a.ts.value ?? a.ts.error), command: "true", cwd: p.dir, station: "Other2" }), "run", ["s1", { grant: rid(a.mb.value), command: "true", cwd: p.dir, station: "Other2" }]);
  // sent there; the other station says how it ended
  const tsRun = s.run("s1", { grant: rid(a.ts.value ?? a.ts.error), command: "echo hi", cwd: p.dir, under: "sub" });
  const mbRun = p.mb.said("run", ["s1", { grant: rid(a.mb.value), command: "echo hi", cwd: p.dir, under: "sub" }]);
  await until("the TypeScript's command sent", () => p.asked.ts.some((x: any) => x[1].method === "vault.run"));
  // (the program's run waits in its queue: what is asked beside it, a station's capabilities, is its turn of the loop)
  await until("the program's command sent", async () => { await p.mb.said("heard", ["nobody", WS, { method: "vault.capabilities" }]); return p.asked.mb.some((x: any) => x[1].method === "vault.run"); });
  const sent = (side: "ts" | "mb") => p.asked[side].filter((x: any) => x[1].method === "vault.run").at(-1) as [string, any];
  assert.deepEqual(namer()(sent("mb")), namer()(sent("ts")));
  await p.both("used", () => s.heard("p1", WS, { method: "vault.used", id: sent("ts")[1].id }), "heard", ["p1", WS, { method: "vault.used", id: sent("mb")[1].id }]);
  await p.both("not that station's", () => s.heard("p2", WS, { method: "vault.done", id: sent("ts")[1].id }), "heard", ["p2", WS, { method: "vault.done", id: sent("mb")[1].id }]);
  const result = { code: 0, signal: null, output: "hi\n", cut: false, timedOut: false, used: true };
  await p.both("done", () => s.heard("p1", WS, { method: "vault.done", id: sent("ts")[1].id, result }), "heard", ["p1", WS, { method: "vault.done", id: sent("mb")[1].id, result }]);
  const [t, m] = [await tsRun, await mbRun];
  assert.equal(m.value, t);
  // asked here by another station
  await p.both("capabilities", () => s.heard("p1", WS, { method: "vault.capabilities" }), "heard", ["p1", WS, { method: "vault.capabilities" }]);
  await p.both("revoke nothing", () => s.heard("p1", WS, { method: "vault.revoke", id: "x_1" }), "heard", ["p1", WS, { method: "vault.revoke", id: "x_1" }]);
  await p.both("unknown", () => s.heard("p1", WS, { method: "vault.nope" }), "heard", ["p1", WS, { method: "vault.nope" }]);
  await p.both("no id", () => s.heard("p1", WS, { method: "vault.run", session: "s9", command: "true" }), "heard", ["p1", WS, { method: "vault.run", session: "s9", command: "true" }]);
  const run = { method: "vault.run", id: `x_${"A".repeat(26)}`, session: "s9", command: "true", under: "../x" };
  await p.both("out of its directory", () => s.heard("p1", WS, run), "heard", ["p1", WS, run]);
  await p.compareDbs("the databases");
});

test("a sign-in from a card: asked, filled, left, done and kept with no card of its own", { skip }, async () => {
  const p = await pair();
  const s = p.signIns;
  p.state.tabs = { s1: [{ id: "T1", url: "https://github.com/login" }] };
  await p.sync();
  await p.both("no reason", () => s.ask("s1", { site: "github.com" }), "signin.ask", ["s1", { site: "github.com" }]);
  await p.both("not a site", () => s.ask("s1", { site: "github", reason: "x" }), "signin.ask", ["s1", { site: "github", reason: "x" }]);
  await p.both("no tab", () => s.ask("s1", { site: "gitlab.com", reason: "x" }), "signin.ask", ["s1", { site: "gitlab.com", reason: "x" }]);
  await p.both("asked", () => s.ask("s1", { site: "https://www.GitHub.com/login", reason: "看日志" }), "signin.ask", ["s1", { site: "https://www.GitHub.com/login", reason: "看日志" }]);
  await p.both("asked again: waiting", () => s.ask("s1", { site: "github.com" }), "signin.ask", ["s1", { site: "github.com" }]);
  const id = `g_${p.now()}`;
  await p.both("got", () => s.get(id), "signin.get", [id]);
  await p.both("not theirs", () => s.fill("bob@x.com", WS, id, { password: "pw" }), "signin.fill", ["bob@x.com", WS, id, { password: "pw" }]);
  await p.both("nothing", () => s.fill("alice@x.com", WS, id, {}), "signin.fill", ["alice@x.com", WS, id, {}]);
  p.forms.drives.push({ state: "left" }, { state: "left" });
  // (filled in the background: what the drive tells is compared once both have)
  const filled = { username: "alice", password: "pw", keep: true };
  const tf = await p.ts(() => s.fill("alice@x.com", WS, id, filled));
  const mf = await p.mb.said("signin.fill", ["alice@x.com", WS, id, filled]);
  // (each side's drive is waited for by its fact, the sign-in left: never a count of turns)
  await until("the TypeScript's drive", () => s.get(id)?.status === "left");
  const t = await p.ts(async () => null);
  const m = { effects: [] as unknown[] };
  await until("the program's drive", async () => {
    const got = await p.mb.said("signin.get", [id]);
    m.effects.push(...got.effects);
    return got.value?.status === "left";
  });
  assert.deepEqual([...mf.effects, ...m.effects], [...tf.effects, ...t.effects], "what the fill and the drive told");
  await p.both("left", () => s.get(id), "signin.get", [id]);
  await p.both("done, kept", () => s.ask("s1", { site: "github.com", done: true, name: "GitHub", about: "the bot's" }), "signin.ask", ["s1", { site: "github.com", done: true, name: "GitHub", about: "the bot's" }]);
  await p.both("after", () => s.get(id), "signin.get", [id]);
  await until("the program's browser", async () => { await p.mb.said("signin.get", ["none"]); return p.browserLog.mb.length >= p.browserLog.ts.length; });
  assert.deepEqual(p.browserLog.mb, p.browserLog.ts);
  await p.compareDbs("the databases");
});

test("what is said and hidden: the forms of a value, a stream scrubbed in pieces, a placeholder swapped, a site, an id", { skip }, async () => {
  const p = await pair();
  const values = ["ghp_abc123", "pa:ss/wo+rd=1", "名字 😀 secret", "ab", "x\"y\\z", "\u{1F600}\u{1F600}"];
  for (const v of values) assert.deepEqual(await p.mb.fn("formsOf", [v]), formsOf(v).map((b) => b.toString("hex")), v);
  const text = "token ghp_abc123, base64 Z2hwX2FiYzEyMw==, url pa%3Ass%2Fwo%2Brd%3D1, json x\\\"y\\\\z, 名字 😀 secret.";
  assert.equal(await p.mb.fn("scrub", [text, values]), scrub(text, values));
  const pieces = ["tok", "en ghp_ab", "c123 and pa:s", "s/wo+rd=1 ", "end"].map((x) => Buffer.from(x).toString("hex"));
  const sc = new Scrubber(values);
  const want = [...pieces.map((h) => sc.push(Buffer.from(h, "hex")).toString("hex")), sc.end().toString("hex")];
  assert.deepEqual(await p.mb.fn("scrubChunks", [values, pieces]), want);
  const run = { placeholder: placeholder("r_X"), value: "s3cr3t" };
  for (const h of ["Bearer stillfail-secret:r_X", `Basic ${Buffer.from("user:stillfail-secret:r_X").toString("base64")}`, "basic   dXNlcjpwYXNz", "stillfail-secret:r_X,stillfail-secret:r_X", "none"])
    assert.equal(await p.mb.fn("swap", [h, run.placeholder, run.value]), swap(h, run), h);
  for (const site of ["https://www.GitHub.com/login?x=1", "github.com:443", "WWW.example.org.", "ftp://a.b/c", "  x.y  ", "a", "git+ssh://host.io/x"])
    assert.equal(await p.mb.fn("siteOf", [site]), siteOf(site), site);
  assert.equal(await p.mb.fn("placeholder", ["r_1"]), placeholder("r_1"));
  const rnd = randomBytes(16);
  for (const ms of [0, 1, T0, 2 ** 47 + 12345]) {
    const real = ulid(ms);
    assert.equal((await p.mb.fn("ulid", [{ ms, random: rnd.toString("hex") }])).slice(0, 10), real.slice(0, 10), String(ms));
  }
});

test("an SSH agent's answers and a proxy's certificates: the same bytes and the same fields", { skip }, async () => {
  const p = await pair();
  // an Ed25519 key in OpenSSH's own format, and an RSA key in PEM
  const ed = generateKeyPairSync("ed25519");
  const seed = (ed.privateKey.export({ format: "der", type: "pkcs8" }) as Buffer).subarray(16);
  const pub = Buffer.from(ed.publicKey.export({ format: "jwk" }).x!, "base64url");
  const str = (b: Buffer | string) => { const v = typeof b === "string" ? Buffer.from(b) : b; const n = Buffer.alloc(4); n.writeUInt32BE(v.length); return Buffer.concat([n, v]); };
  const u32 = (n: number) => { const b = Buffer.alloc(4); b.writeUInt32BE(n); return b; };
  const blob = Buffer.concat([str("ssh-ed25519"), str(pub)]);
  const priv = Buffer.concat([u32(7), u32(7), str("ssh-ed25519"), str(pub), str(Buffer.concat([seed, pub])), str("me@host")]);
  const raw = Buffer.concat([Buffer.from("openssh-key-v1\0"), str("none"), str("none"), str(""), u32(1), str(blob), str(priv)]);
  const opensshEd = `-----BEGIN OPENSSH PRIVATE KEY-----\n${raw.toString("base64").replace(/.{70}/g, "$&\n")}\n-----END OPENSSH PRIVATE KEY-----\n`;
  const rsaPem = generateKeyPairSync("rsa", { modulusLength: 2048 }).privateKey.export({ format: "pem", type: "pkcs8" }) as string;
  for (const [what, text] of [["ed25519", opensshEd], ["rsa", rsaPem]] as const) {
    const k = parseSshKey(text);
    assert.deepEqual(await p.mb.fn("sshKey", [text]), { kind: k.kind, comment: k.comment, blob: k.blob.toString("hex") }, what);
    const list = Buffer.from([11]);
    const signReq = (flags: number) => Buffer.concat([Buffer.from([13]), str(k.blob), str(Buffer.from("data to sign")), u32(flags)]);
    for (const [m, allowed] of [[list, true], [signReq(0), true], [signReq(2), true], [signReq(4), true], [signReq(0), false], [Buffer.from([13, 0, 0]), true], [Buffer.from([99]), true]] as const)
      assert.equal(await p.mb.fn("sshAnswer", [text, m.toString("hex"), allowed]), agentAnswer(k, m, () => allowed).toString("hex"), `${what} ${m[0]}`);
  }
  // a CA and a leaf: what a verifier reads of them the same as of the TypeScript's, and signed by it
  const now = T0;
  const mbCa = await p.mb.fn("makeCa", [{ now }, "still.fail station vault"]);
  const mbLeaf = await p.mb.fn("makeLeaf", [mbCa.cert, mbCa.key, "still.fail station vault", "api.github.com", { now }]);
  const tsCa = makeCa(now), tsLeaf = makeLeaf(tsCa, "still.fail station vault", "api.github.com", now);
  const read = (der: Buffer) => { const c = new X509Certificate(der); return { subject: c.subject, issuer: c.issuer, from: c.validFrom, to: c.validTo, san: c.subjectAltName, ca: c.ca, keyUsage: c.keyUsage }; };
  assert.deepEqual(read(Buffer.from(mbCa.cert, "hex")), read(tsCa.cert));
  assert.deepEqual(read(Buffer.from(mbLeaf.cert, "hex")), read(tsLeaf.cert));
  const ca = new X509Certificate(Buffer.from(mbCa.cert, "hex"));
  assert.ok(new X509Certificate(Buffer.from(mbLeaf.cert, "hex")).verify(ca.publicKey));
  assert.ok(ca.verify(ca.publicKey));
  assert.equal(await p.mb.fn("pem", [tsCa.cert.toString("hex")]), pem(tsCa.cert));
  // the proxy's decisions (its sockets are the machine's): a CONNECT named by its run, opened for the grant's hosts
  void Incoming;
});

test("a restart and a handover: the plain library's grants taken up from the database, what memory held carried over", { skip }, async () => {
  const p = await pair();
  const s = p.secrets;
  const rid = (v: unknown) => /r_[0-9A-Z]{26}/.exec(String(v))![0];
  const save = { name: "Token", kind: "token", reason: "存", value: "tok_restart_123", about: "t", cwd: p.dir, modes: ["env"] };
  const k = await p.both("save", () => s.save("s1", save), "save", ["s1", save]);
  await p.both("kept", () => s.savedPlain(WS, null, "alice@x.com", { request: rid(k.ts.value) }), "savedPlain", [WS, "alice@x.com", { request: rid(k.mb.value) }]);
  await p.at(T0 + 1000);
  const a = await p.both("asked", () => s.ask("s1", { item: "Token", reason: "r" }), "ask", ["s1", { item: "Token", reason: "r" }]);
  await p.both("granted", () => s.grantPlain(WS, null, "alice@x.com", { request: rid(a.ts.value), scope: "chat" }), "grantPlain", [WS, "alice@x.com", { request: rid(a.mb.value), scope: "chat" }]);
  // a secret waiting to be kept, held only in memory
  await p.at(T0 + 2000);
  const waiting = { name: "Second", kind: "token", reason: "存", value: "tok_waiting_456", about: "w", cwd: p.dir };
  const wk = await p.both("save waiting", () => s.save("s1", waiting), "save", ["s1", waiting]);
  const tsCarried = s.carried();
  const mbCarried = await p.mb.fn("carried");
  assert.deepEqual(namer()(mbCarried), namer()(JSON.parse(JSON.stringify(tsCarried))));
  // the next process on the same database, given what this one held
  const q = await pair({ from: { tsPath: p.tsDb.location()!, mbPath: p.mbPath, data: p.data, dir: p.dir, now: T0 + 3000 } });
  await q.both("restored", () => q.secrets.held("s1"), "held", ["s1"]);
  await q.both("carry", () => { q.secrets.carry(tsCarried); return null; }, "carry", [mbCarried]);
  await q.both("held after", () => q.secrets.held("s1"), "held", ["s1"]);
  await q.both("the waiting one kept", () => q.secrets.savedPlain(WS, null, "alice@x.com", { request: rid(wk.ts.value) }), "savedPlain", [WS, "alice@x.com", { request: rid(wk.mb.value) }]);
  const command = `printf '%s\\n' "$STILLFAIL_SECRET"`;
  await q.both("run after", () => q.secrets.run("s1", { grant: rid(a.ts.value), command, cwd: p.dir }), "run", ["s1", { grant: rid(a.mb.value), command, cwd: p.dir }]);
  // the chat archived: its grants let go
  q.state.sessions.s1!.archivedAt = 1;
  await q.sync();
  await q.both("archived", () => q.secrets.held("s1"), "held", ["s1"]);
  await q.compareDbs("the databases");
});

test("a sign-in kept from the chat's browser, granted into it, used, put in again and its newer cookies kept", { skip }, async () => {
  const p = await pair();
  const s = p.secrets;
  const rid = (v: unknown) => /r_[0-9A-Z]{26}/.exec(String(v))![0];
  p.browser.jar = "[]";
  const save = { name: "GitHub 登录态", kind: "browser", reason: "存登录", hosts: ["github.com"], about: "the bot", cwd: p.dir };
  await p.both("no cookies", () => s.save("s1", save), "save", ["s1", save]);
  p.browser.jar = JSON.stringify([{ name: "sid", value: "abc", domain: ".github.com", path: "/" }]);
  const k = await p.both("save", () => s.save("s1", save), "save", ["s1", save]);
  await p.both("kept", () => s.savedPlain(WS, null, "alice@x.com", { request: rid(k.ts.value) }), "savedPlain", [WS, "alice@x.com", { request: rid(k.mb.value) }]);
  await settle();
  await p.at(T0 + 1000);
  const ask = { item: "GitHub 登录态", reason: "看", timeout: { kind: "idle" as const, seconds: 600 } };
  const a = await p.both("asked", () => s.ask("s1", ask), "ask", ["s1", ask]);
  await p.both("granted", () => s.grantPlain(WS, null, "alice@x.com", { request: rid(a.ts.value), scope: "hour", timeout: ask.timeout }), "grantPlain", [WS, "alice@x.com", { request: rid(a.mb.value), scope: "hour", timeout: ask.timeout }]);
  await settle();
  await p.both("used", () => s.browserUsed("s1", "api.github.com"), "browserUsed", ["s1", "api.github.com"]);
  await p.both("put in again", () => s.signInAgain("s1"), "signInAgain", ["s1"]);
  await p.both("passkeys again", () => s.passkeysAgain("s1"), "passkeysAgain", ["s1"]);
  await settle();
  await p.both("run refused", () => s.run("s1", { grant: rid(a.ts.value), command: "true", cwd: p.dir }), "run", ["s1", { grant: rid(a.mb.value), command: "true", cwd: p.dir }]);
  const cookies = JSON.stringify([{ name: "sid", value: "newer", domain: ".github.com", path: "/" }]);
  await p.both("renewed", () => s.renewed("s1", rid(a.ts.value), cookies, WS), "renewed", ["s1", rid(a.mb.value), cookies, WS]);
  await p.both("renewed by its old lookup", () => s.renewed("s1", rid(a.ts.value), cookies), "renewed", ["s1", rid(a.mb.value), cookies]);
  // (a sign-in is put into the browser in the background on each side: both its puts there before they are compared)
  await until("the program's sign-ins", async () => { await p.mb.said("signin.get", ["none"]); return p.browserLog.mb.length >= p.browserLog.ts.length; });
  const n = namer(), m = namer();
  assert.deepEqual(m(p.browserLog.mb), n(p.browserLog.ts));
  await p.compareDbs("the databases");
});

test("through the proxy and the agent: HTTPS to a granted host given the value, an SSH key listed by its agent", { skip }, async () => {
  // an upstream on this machine, its certificate of a CA of the test's own
  // (the certificates a client checks against the machine's own time: this test's clock is the wall's)
  const start = wall.now();
  const ca = makeCa(start, "test upstream"), leaf = makeLeaf(ca, "test upstream", "localhost", start);
  const seen: string[] = [];
  const upstream = createHttpsServer({ key: leaf.key.export({ format: "pem", type: "pkcs8" }), cert: pem(leaf.cert) + pem(ca.cert) }, (req, res) => {
    seen.push(String(req.headers.authorization));
    res.end(`saw ${req.headers.authorization === "Bearer ghp_upstream_value_42" ? "the value" : "something else"}\n`);
  });
  await new Promise<void>((r) => upstream.listen(0, "localhost", () => r()));
  closers.push(() => new Promise<void>((r) => { upstream.close(() => r()); upstream.closeAllConnections(); }));
  const port = (upstream.address() as { port: number }).port;
  const p = await pair({ trust: [pem(ca.cert)], start });
  const s = p.secrets;
  const rid = (v: unknown) => /r_[0-9A-Z]{26}/.exec(String(v))![0];
  const save = { name: "Upstream", kind: "token", reason: "存", value: "ghp_upstream_value_42", hosts: ["localhost"], env: "TOKEN", about: "u", cwd: p.dir };
  const k = await p.both("save", () => s.save("s1", save), "save", ["s1", save]);
  await p.both("kept", () => s.savedPlain(WS, null, "alice@x.com", { request: rid(k.ts.value) }), "savedPlain", [WS, "alice@x.com", { request: rid(k.mb.value) }]);
  // (Node's own client, given the proxy and the bundle by the environment the run sets)
  const command = `NODE_USE_ENV_PROXY=1 ${JSON.stringify(process.execPath)} -e 'fetch("https://localhost:${port}/", { headers: { authorization: "Bearer " + process.env.TOKEN } }).then((r) => r.text()).then((t) => process.stdout.write(t), (e) => { console.log(String(e.cause ?? e)); process.exit(1); })'`;
  const ran = await p.both("through the proxy", () => s.run("s1", { grant: rid(k.ts.value), command, cwd: p.dir }), "run", ["s1", { grant: rid(k.mb.value), command, cwd: p.dir }]);
  assert.match(String(ran.ts.value), /saw the value/);
  assert.deepEqual(seen, ["Bearer ghp_upstream_value_42", "Bearer ghp_upstream_value_42"]);
  // an SSH key given by its agent
  let sshAdd = true;
  try { execFileSync("sh", ["-c", "command -v ssh-add"]); } catch { sshAdd = false; }
  if (sshAdd) {
    await p.at(start + 1000);
    const pair2 = generateKeyPairSync("ed25519");
    const seed = (pair2.privateKey.export({ format: "der", type: "pkcs8" }) as Buffer).subarray(16);
    const pub = Buffer.from(pair2.publicKey.export({ format: "jwk" }).x!, "base64url");
    const str = (b: Buffer | string) => { const v = typeof b === "string" ? Buffer.from(b) : b; const n = Buffer.alloc(4); n.writeUInt32BE(v.length); return Buffer.concat([n, v]); };
    const u32 = (n: number) => { const b = Buffer.alloc(4); b.writeUInt32BE(n); return b; };
    const blob = Buffer.concat([str("ssh-ed25519"), str(pub)]);
    const raw = Buffer.concat([Buffer.from("openssh-key-v1\0"), str("none"), str("none"), str(""), u32(1), str(blob), str(Buffer.concat([u32(9), u32(9), str("ssh-ed25519"), str(pub), str(Buffer.concat([seed, pub])), str("bot@ci")]))]);
    const key = `-----BEGIN OPENSSH PRIVATE KEY-----\n${raw.toString("base64")}\n-----END OPENSSH PRIVATE KEY-----\n`;
    const sk = { name: "Deploy SSH", kind: "ssh_key", reason: "存", value: key, about: "ssh", cwd: p.dir };
    const kk = await p.both("an SSH key", () => s.save("s1", sk), "save", ["s1", sk]);
    await p.both("kept", () => s.savedPlain(WS, null, "alice@x.com", { request: rid(kk.ts.value) }), "savedPlain", [WS, "alice@x.com", { request: rid(kk.mb.value) }]);
    const listed = await p.both("listed by its agent", () => s.run("s1", { grant: rid(kk.ts.value), command: "ssh-add -L", cwd: p.dir }), "run", ["s1", { grant: rid(kk.mb.value), command: "ssh-add -L", cwd: p.dir }]);
    assert.match(String(listed.ts.value), new RegExp(`ssh-ed25519 ${blob.toString("base64").replace(/[+/]/g, "\\$&")} bot@ci`));
  }
  await p.compareDbs("the databases");
});
