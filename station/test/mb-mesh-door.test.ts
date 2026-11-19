// The mesh's wire and door in MoonBit (station/mb src/mesh_door) held to the TypeScript (src/mesh/wire.ts, door.ts,
// compress.ts, and the parts of serve.ts and peer.ts the program has) both ways, end to end: a TypeScript client on a
// MoonBit door and a MoonBit client on a TypeScript door, each transcript the one the same client hears of a door in
// its own language: the hello let in or refused (its line, then the close with its code and reason once the clock
// passed REFUSED_CLOSE_MS), renewals answered, refused, and one that ends the connection (the streams after it reset),
// requests on streams at once (a body of 300 KB both ways in pieces, JSON and an event stream compressed with zstd).
// The program is `stillfail-reader-harness --builder harness-mesh-door` (mesh_door/harness.mbt), its connections carried as
// lines (mesh_door/bridge.mbt) on a clock each side moves only as the test says.
import assert from "node:assert/strict";
import { type ChildProcess, spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { constants, zstdDecompressSync } from "node:zlib";
import { after, mock, test } from "node:test";
import { mbHarnessBinary } from "./mb-harness.ts";
import { type Admit, Ending, door } from "../src/mesh/door.ts";
import { type Answer, Reader, send, writeLine } from "../src/mesh/wire.ts";
import { compressed } from "../src/mesh/compress.ts";
import { wall } from "../src/ops/fibers.ts";
import type { Connection, Stream } from "../src/mesh/endpoint.ts";
import { memoryMesh } from "./memory-mesh.ts";
import type { Cloud } from "../src/cloud/state.ts";
import { type LockState, LockRefusal, admit, admitPerson, asEntry, endpointProof, fold, personFold } from "../src/cloud/lock.ts";
import { hashOf } from "../src/cloud/log-keep.ts";
import { inLock, inLockBringing, lockPartRoute, lockRoute, movedFloor, ownChainsOf, personChainsOf, refusalOf, stationMarksRoute, stillIn, waysRoute } from "../src/mesh/serve.ts";
import { deviceBuildsOf } from "../src/mesh/device-builds.ts";
import { WaysRefusal, answerWays, setRelays, setWay, waysOf } from "../src/mesh/ways.ts";
import { MarkRefusal, answerMarks, stationMarksOf } from "../src/mesh/station-marks.ts";
import { pinBrought } from "../src/mesh/moved-pin.ts";
import { checkChain } from "../src/mesh/person-sync.ts";
import { STILLFAIL } from "../src/cloud/provider.ts";
import { COUNTED_FROM, OLDEST_CORE } from "../src/api/oldest.ts";
import { LOGS_ANY_FROM_BUILD, LOGS_BEFORE, MOVED_FROM_BUILD, ROOT_OUT_FROM_BUILD } from "../src/api/moved-from.ts";

const binary = mbHarnessBinary();
const skip = binary === null ? "the tests' MoonBit program (stillfail-reader-harness) is not built here" : false;

// The machine's timers are the test's (door.ts arms a refusal's close by `wall.after`): moved on only by `fire`.
type Timer = { ms: number; fire: () => void; off: boolean };
const timers: Timer[] = [];
mock.method(wall, "after", (ms: number, fire: () => void) => {
  const timer: Timer = { ms, fire, off: false };
  timers.push(timer);
  return () => void (timer.off = true);
});
/// Every timer armed and not called off, fired (the clock moved on past them all).
const fireTimers = () => {
  for (const t of timers.splice(0)) if (!t.off) t.fire();
};

/// The program, driven a line at a time: each line answered `{ack}` once all it set going is done.
class Harness {
  readonly child: ChildProcess;
  #id = 0;
  #acks = new Map<number, () => void>();
  #answers = new Map<number, (v: any) => void>();
  #listeners = new Map<number, (ev: any) => void>();
  readonly ready: Promise<void>;
  readonly defects: string[] = [];
  constructor(bin: string) {
    const dir = mkdtempSync(join(tmpdir(), "mesh-door-"));
    after(() => rmSync(dir, { recursive: true, force: true }));
    this.child = spawn(bin, ["--builder", "harness-mesh-door", "--shell-dir", dir], { stdio: ["pipe", "pipe", "inherit"] });
    let readied!: () => void;
    this.ready = new Promise((r) => (readied = r));
    createInterface({ input: this.child.stdout! }).on("line", (text) => {
      const line = JSON.parse(text);
      if (line.ready) readied();
      else if (line.defect) this.defects.push(line.defect);
      else if (typeof line.ack === "number") this.#acks.get(line.ack)?.();
      else if (typeof line.answer === "number") this.#answers.get(line.answer)?.(line);
      else if (typeof line.keeper === "number") void this.#kept(line);
      else if (typeof line.conn === "number") this.#listeners.get(line.conn)?.(line);
    });
  }
  /// A line told the program, once it has done all it set going.
  tell(line: Record<string, unknown>): Promise<void> {
    const id = ++this.#id;
    return new Promise((resolve) => {
      this.#acks.set(id, () => {
        this.#acks.delete(id);
        resolve();
      });
      this.child.stdin!.write(JSON.stringify({ ...line, id }) + "\n");
    });
  }
  /// One of the package's functions asked: what it answered (`ok`) or failed with (`error`).
  call(fn: string, args: Record<string, unknown> = {}): Promise<{ ok?: any; error?: string; lock?: boolean }> {
    const id = this.#id + 1;
    const answered = new Promise<any>((r) => this.#answers.set(id, r));
    void this.tell({ op: "call", fn, ...args });
    return answered.then((a) => {
      this.#answers.delete(id);
      return a;
    });
  }
  /// The cloud and rules the program's keeper asks (`Keeper::asking`): the TypeScript station's, of the world given.
  keeper: ((fn: string, args: any) => unknown) | null = null;
  async #kept(line: { keeper: number; fn: string; args: any }) {
    let said: Record<string, unknown>;
    try {
      if (this.keeper === null) throw new Error("no keeper given");
      said = { value: (await this.keeper(line.fn, line.args)) ?? null };
    } catch (e) {
      const kind = e instanceof LockRefusal ? "lock" : e instanceof WaysRefusal ? "ways" : e instanceof MarkRefusal ? "mark" : "error";
      said = { error: (e as Error).message, kind };
    }
    void this.tell({ op: "kept", n: line.keeper, ...said });
  }
  listen(conn: number, f: (ev: any) => void) {
    this.#listeners.set(conn, f);
  }
  close() {
    this.child.stdin!.end();
  }
}

/// What a closed connection says: who closed it, with what code and reason.
type Closed = { closed: boolean; by_peer?: boolean; code?: number; reason?: string };

/// A TypeScript end of a connection the program carries (bridge.mbt's far end, as lines).
class FarConn implements Connection {
  readonly #h: Harness;
  readonly #id: number;
  readonly #remote: string;
  #streams = new Map<string, FarStream>();
  #incoming: FarStream[] = [];
  #accepting: ((s: FarStream | null) => void) | null = null;
  #opened = 0;
  closedRec: Closed = { closed: false };
  #resolve!: (r: string) => void;
  #closed = new Promise<string>((r) => (this.#resolve = r));
  readonly #alpn: Buffer;
  constructor(h: Harness, id: number, remote: string, alpn = "interop/1") {
    this.#h = h;
    this.#id = id;
    this.#remote = remote;
    this.#alpn = Buffer.from(alpn);
    h.listen(id, (ev) => this.#heard(ev));
  }
  #heard(ev: any) {
    if (ev.ev === "open") {
      const s = new FarStream(this.#h, this.#id, ev.stream);
      this.#streams.set(ev.stream, s);
      const take = this.#accepting;
      this.#accepting = null;
      if (take) take(s);
      else this.#incoming.push(s);
      return;
    }
    if (ev.ev === "close") return this.#gone(true, ev.code, ev.reason);
    const s = this.#streams.get(ev.stream);
    if (ev.ev === "data") s?.push(Buffer.from(ev.b64, "base64"));
    else if (ev.ev === "fin") s?.push(null);
    else if (ev.ev === "reset") s?.push(new Error(ev.code));
    else if (ev.ev === "stopped") s?.stoppedWith(ev.code);
    else this.onOther(ev);
  }
  /// What the program says of this connection that is not of its streams (a door's end, a client's result).
  onOther: (ev: any) => void = () => {};
  #gone(byPeer: boolean, code: number, reason: string) {
    if (this.closedRec.closed) return;
    this.closedRec = { closed: true, by_peer: byPeer, code, reason };
    for (const s of this.#streams.values()) s.push(new Error("connection lost"));
    const take = this.#accepting;
    this.#accepting = null;
    take?.(null);
    this.#resolve(reason);
  }
  remoteId() { return this.#remote; }
  alpn() { return this.#alpn; }
  via() { return null; }
  async acceptBi(): Promise<Stream | null> {
    if (this.#incoming.length > 0) return this.#incoming.shift()!;
    if (this.closedRec.closed) return null;
    return new Promise((r) => (this.#accepting = r));
  }
  async openBi(): Promise<Stream> {
    if (this.closedRec.closed) throw new Error("connection lost");
    const sid = `t${++this.#opened}`;
    const s = new FarStream(this.#h, this.#id, sid);
    this.#streams.set(sid, s);
    await this.#h.tell({ op: "ev", ev: "open", conn: this.#id, stream: sid });
    return s;
  }
  close(code: number, reason: string) {
    if (this.closedRec.closed) return;
    void this.#h.tell({ op: "ev", ev: "close", conn: this.#id, code, reason });
    this.#gone(false, code, reason);
  }
  isClosed() { return this.closedRec.closed; }
  closed() { return this.#closed; }
  closeReason() { return this.closedRec.closed ? { kind: this.closedRec.by_peer ? "application" : "local", reason: this.closedRec.reason! } : null; }
}

class FarStream implements Stream {
  readonly #h: Harness;
  readonly #conn: number;
  readonly #sid: string;
  #pieces: (Buffer | null | Error)[] = [];
  #reading: ((p: Buffer | null | Error) => void) | null = null;
  #done = false;
  #stopped: Promise<number | null>;
  #stop!: (c: number | null) => void;
  constructor(h: Harness, conn: number, sid: string) {
    this.#h = h;
    this.#conn = conn;
    this.#sid = sid;
    this.#stopped = new Promise((r) => (this.#stop = r));
  }
  push(p: Buffer | null | Error) {
    const take = this.#reading;
    this.#reading = null;
    if (take) take(p);
    else this.#pieces.push(p);
  }
  stoppedWith(code: number | null) { this.#stop(code); }
  async read(): Promise<Buffer | null> {
    if (this.#done) return null;
    const p = this.#pieces.length > 0 ? this.#pieces.shift()! : await new Promise<Buffer | null | Error>((r) => (this.#reading = r));
    if (p === null) this.#done = true;
    if (p instanceof Error) {
      this.#done = true;
      throw p;
    }
    return p;
  }
  #ev(ev: string, more: Record<string, unknown> = {}) {
    return this.#h.tell({ op: "ev", ev, conn: this.#conn, stream: this.#sid, ...more });
  }
  write(bytes: Buffer) { return this.#ev("data", { b64: bytes.toString("base64") }); }
  finish() { return this.#ev("fin"); }
  stopped() { return this.#stopped; }
  reset(code: number) { return this.#ev("reset", { code }); }
}

// The interop admission, client and answers: mesh_door/interop.mbt's, word for word.

const item = (i: number) => ({ i, words: `item ${i} of a list that says much the same each time` });
const nOf = (path: string) => Number(/n=(\d+)/.exec(path)?.[1] ?? 0);

function interopAdmit(): Admit {
  return (hello) => {
    if (hello?.credential !== "good") return { refused: { line: { error: "refused", code: "nope" }, code: 1, reason: "credential_refused", error: new Error("refused") } };
    return {
      line: { ok: true, expires_at: 99 },
      renew: (line) => {
        if (line?.credential === "good") return { ok: true, renewed: true };
        if (line?.credential === "end") throw new Ending("revoked", 3, "credential_revoked");
        throw new Error("bad renewal");
      },
      stream: () => async (asked) => {
        const path: string = asked.head.path;
        const headers: Record<string, string> = asked.head.headers ?? {};
        let answer: Answer;
        if (path.startsWith("/echo")) answer = { status: 200, headers: { "content-type": "application/octet-stream" }, body: await asked.reader.rest() };
        else if (path.startsWith("/json")) answer = { status: 200, headers: { "content-type": "application/json" }, body: Buffer.from(JSON.stringify(Array.from({ length: nOf(path) }, (_, i) => item(i)))) };
        else if (path.startsWith("/events")) {
          const n = nOf(path);
          answer = { status: 200, headers: { "content-type": "text/event-stream" }, body: (async function* () {
            for (let i = 1; i <= n; i++) yield Buffer.from(`data: ${JSON.stringify(item(i))}\n\n`);
          })() };
        } else answer = { status: 404, headers: { "content-type": "application/json" }, body: Buffer.from('{"error":"none"}') };
        await send(asked.stream, await compressed(answer, headers, path));
        await asked.stream.finish();
      },
    };
  };
}

const checksum = (b: Buffer) => {
  let h = 0;
  for (const x of b) h = (Math.imul(h, 31) + x) & 0x7fffffff;
  return h;
};

/// The interop client on `conn`: what it heard, in order (interop.mbt `interop_client`).
async function interopClient(conn: Connection, hellos: unknown[], advance: () => Promise<void>, closedOf: () => Closed): Promise<unknown[]> {
  const said: unknown[] = [];
  const control = await conn.openBi();
  const r = new Reader(control);
  await writeLine(control, hellos[0]);
  said.push(await r.line());
  if ((said[0] as any)?.ok !== true) {
    await advance();
    await conn.closed().catch(() => {});
    said.push(closedOf());
    return said;
  }
  for (const h of hellos.slice(1)) {
    await writeLine(control, h);
    said.push(await r.line());
  }
  const big = Buffer.alloc(300 * 1024);
  for (let i = 0; i < big.length; i++) big[i] = (i * 7) % 251;
  const asks: [string, Buffer, Record<string, string>][] = [
    ["/echo", big, {}],
    ["/json?n=300", Buffer.alloc(0), { "accept-encoding": "gzip, zstd" }],
    ["/events?n=5", Buffer.alloc(0), { "accept-encoding": "zstd" }],
    ["/json?n=3", Buffer.alloc(0), { "accept-encoding": "zstd" }],
  ];
  const answers = await Promise.all(asks.map(async ([path, body, headers]) => {
    const s = await conn.openBi();
    await writeLine(s, { method: "GET", path, headers });
    for (let at = 0; at < body.length; at += 65536) await s.write(body.subarray(at, Math.min(at + 65536, body.length)));
    await s.finish();
    const rr = new Reader(s);
    const head = await rr.line();
    const got = await rr.rest();
    const plain = head?.headers?.["content-encoding"] === "zstd" ? zstdDecompressSync(got, { finishFlush: constants.ZSTD_e_flush }) : got;
    return { head, size: plain.length, sum: checksum(plain), text: plain.length < 20000 && path !== "/echo" ? plain.toString() : "" };
  }));
  said.push(...answers);
  await writeLine(control, { credential: "end" });
  said.push(await r.line());
  const s = await conn.openBi();
  await writeLine(s, { method: "GET", path: "/json?n=1" });
  said.push(await s.read().then((b) => (b === null ? "end" : "data"), (e: Error) => e.message));
  await advance();
  await conn.closed().catch(() => {});
  said.push(closedOf());
  return said;
}

/// A connection in memory between two TypeScript ends (memory-mesh.ts), each close's code kept as it is said.
async function tsPair(): Promise<{ client: Connection; server: Connection; closedOf: () => Closed }> {
  const mesh = memoryMesh();
  const alpn = Buffer.from("interop/1");
  const bind = () => mesh.bind({ secretKey: randomBytes(32), alpns: [alpn], relayUrls: [], discovery: false });
  const [at, dev] = await Promise.all([bind(), bind()]);
  after(() => Promise.all([at.close(), dev.close()]));
  const [client, server] = await Promise.all([dev.connect({ id: at.id() }, alpn), at.accept()]);
  let rec: Closed = { closed: false };
  const close = server!.close.bind(server);
  server!.close = (code, reason) => {
    if (!rec.closed) rec = { closed: true, by_peer: true, code, reason };
    close(code, reason);
  };
  return { client, server: server!, closedOf: () => rec };
}

/// The TypeScript door serving `conn` as accept.ts serves one: closed with code 0 once served no more.
const tsDoor = (conn: Connection) => void door(conn, interopAdmit()).catch(() => {}).finally(() => conn.close(0, "served"));

const HELLOS: Record<string, unknown[]> = {
  refused: [{ credential: "bad" }],
  renewed: [{ credential: "good" }, { credential: "good" }, { credential: "who" }],
};

let nextConn = 0;

for (const [name, hellos] of Object.entries(HELLOS)) {
  test(`${name}: a TypeScript client hears a MoonBit door as it hears a TypeScript one`, { skip }, async () => {
    // TypeScript to TypeScript: what it is to hear.
    timers.length = 0;
    const ts = await tsPair();
    tsDoor(ts.server);
    const expected = await interopClient(ts.client, hellos, async () => fireTimers(), ts.closedOf);

    const h = new Harness(binary!);
    after(() => h.close());
    await h.ready;
    const id = ++nextConn;
    const conn = new FarConn(h, id, "mb");
    await h.tell({ op: "conn", conn: id, role: "door", here: "mb", remote: "ts" });
    const heard = await interopClient(conn, hellos, () => h.tell({ op: "advance", ms: 200 }), () => ({ ...conn.closedRec, by_peer: true }));
    assert.deepEqual(heard, expected);
    assert.deepEqual(h.defects, []);
  });

  test(`${name}: a MoonBit client hears a TypeScript door as a TypeScript client does`, { skip }, async () => {
    timers.length = 0;
    const ts = await tsPair();
    tsDoor(ts.server);
    const expected = await interopClient(ts.client, hellos, async () => fireTimers(), ts.closedOf);

    timers.length = 0;
    const h = new Harness(binary!);
    after(() => h.close());
    await h.ready;
    const id = ++nextConn;
    const conn = new FarConn(h, id, "mb");
    const result = new Promise<any>((resolve) => {
      conn.onOther = (ev) => {
        if (ev.ev === "result") resolve(ev.said);
        else if (ev.ev === "advance") {
          fireTimers();
          void h.tell({ op: "advanced" });
        }
      };
    });
    await h.tell({ op: "conn", conn: id, role: "client", here: "mb", remote: "ts", hellos });
    tsDoor(conn);
    const heard = await result;
    // What the TypeScript client said of a close it made itself (the door's, here the TypeScript's) is the same either
    // way: the door's close reached the client.
    assert.deepEqual(heard, expected.map((x: any) => (x && typeof x === "object" && "closed" in x ? { ...x, by_peer: true } : x)));
    assert.deepEqual(h.defects, []);
  });
}


// The admission and the lock's routes (serve.ts), held to the TypeScript on the same station: the program's keeper asks
// this process's Cloud and rules (`keeperOf`), each case run on a station of its own made the same (what a case takes
// is kept by the station it runs on).

/// A lock's state as the program reads it, kept here by its number for the rules to be given back.
function keeperOf(cloud: Cloud, peerAsk: ((station: string, ws: string | null, request: any) => unknown) | null = null): (fn: string, args: any) => unknown {
  const states: LockState[] = [];
  const view = (s: LockState | null | undefined) => {
    if (!s) return null;
    states.push(s);
    return {
      ref: states.length - 1, seq: s.seq, head: s.head, genesis: s.genesis, ...(s.moved !== undefined ? { moved: s.moved } : {}),
      devices: Object.fromEntries([...s.devices].map(([id, d]) => [id, { id, sub: d.sub, kind: d.kind, ...(d.by !== undefined ? { by: d.by } : {}), ...(d.sign_key !== undefined ? { sign_key: d.sign_key } : {}) }])),
      members: Object.fromEntries([...s.members].map(([sub, m]) => [sub, m.role])),
      stations: [...s.stations.keys()],
      persons: Object.fromEntries(s.persons),
    };
  };
  const lockedView = (l: { state: LockState | null; waiting?: true } | null) => (l === null ? null : { state: view(l.state), waiting: l.waiting === true });
  const chains = personChainsOf(cloud);
  const who = (w: any) => ({ sub: w.sub, endpoint: w.endpoint, ...(w.base !== null ? { base: w.base } : {}), ...(w.proof !== null ? { proof: w.proof } : {}) });
  return (fn, a) => {
    switch (fn) {
      case "home": return cloud.home();
      case "removed": return cloud.removed();
      case "station": return cloud.state?.station ?? "";
      case "name": return cloud.state?.name ?? "";
      case "membership": return cloud.membership(a.ws);
      case "memberships": return cloud.memberships();
      case "grantKeys": return cloud.grantKeys(a.ws);
      case "stateGrantKeys": return cloud.state?.grant_keys ?? null;
      case "joinedRevocations": return cloud.state?.joined?.find((j) => j.workspace === a.ws)?.revocations ?? [];
      case "accepted": return STILLFAIL.credential;
      case "leftOut": return cloud.leftOut(a.ws);
      case "chain": { const c = cloud.chain(a.ws); return c === null ? null : { state: view(c.state) }; }
      case "locked": return lockedView(cloud.locked(a.ws));
      case "list": return lockedView(cloud.list(a.ws));
      case "rootOut": return cloud.rootOut(a.ws);
      case "needs": return cloud.needs(a.ws).size;
      case "takeLock": return cloud.takeLock(a.entries, a.ws);
      case "keepLock": { const t = cloud.keepLock(a.entries, a.ws, a.keep); return { taken: t.taken, off: t.off, refusal: t.refusal?.message ?? null }; }
      case "lockAfter": return cloud.lockAfter(a.seq, a.ws);
      case "takeBodies": return cloud.takeBodies(a.ws, a.bodies);
      case "bodies": return [...cloud.bodies(a.ws).all()];
      case "lacking": return cloud.lacking(a.ws);
      case "logsOf": return cloud.logsOf(a.ws);
      case "givenTo": { const g = cloud.givenTo(a.ws, a.key); return g === "all" ? "all" : [...g]; }
      case "pinBrought": return pinBrought(cloud, a.ws, a.workspace, a.entries, a.logs, a.bodies, who(a.who), a.station);
      case "personOf": return chains.of(a.sub).map(([genesis, entries]) => ({ genesis, entries }));
      case "personKept": return chains.kept(a.genesis);
      case "personChosen": return chains.chosen(a.pin, a.sub, a.raw);
      case "personKeep": return chains.keep(a.pin, a.chain, a.ws);
      case "personTake": return chains.take(a.genesis, a.whose, a.chain, a.ws, a.fork);
      case "personEvery": return chains.every().map(([genesis, entries]) => ({ genesis, entries }));
      case "personsWritten": return chains.written();
      case "admit": { const out = admit(states[a.state]!, who(a.who), a.now); return { device: out.device, role: out.role }; }
      case "admitPerson": { const out = admitPerson(states[a.state]!, who(a.who), a.entries); return { device: out.device, role: out.role }; }
      case "personFold": return personFold(a.entries, a.sub);
      case "fold": return view(fold(a.entries, a.now));
      case "endpointProof": return endpointProof(a.ws, a.base, a.endpoint, a.proof);
      case "asEntry": return asEntry(a.v);
      case "hashOf": return hashOf(a.e);
      case "checkChain": return checkChain(chains, a.chain, a.sub);
      case "buildsSaw": return deviceBuildsOf(cloud).saw(a.id, a.build, a.now);
      case "buildsOf": return deviceBuildsOf(cloud).of(a.ids);
      case "waysView": return waysOf(cloud).view(a.ws);
      case "waysSetRelays": return setRelays(waysOf(cloud), a.ws, a.relays, a.by);
      case "waysSetWay": return setWay(waysOf(cloud), a.ws, a.way, a.on);
      case "marksOf": return stationMarksOf(cloud).of(a.ws);
      case "marksChange": return stationMarksOf(cloud).change(a.change, a.was);
      case "lockKept": return cloud.lockKept(a.ws);
      case "lockOff": { const o = cloud.lockOff(a.ws); return o === null ? null : { entries: o.entries, aside: o.aside }; }
      case "personHeardIn": return chains.heardIn(a.ws).map(([genesis, entries]) => ({ genesis, entries }));
      case "personAll": return chains.all(a.genesis);
      case "personAsideOf": return chains.asideOf(a.genesis);
      case "forceWord": return cloud.forceWord(a.ws);
      case "peersCurrent": return cloud.peersCurrent;
      case "hasState": return cloud.state !== null;
      case "isRig": return cloud.state?.rig !== undefined;
      case "memberOf": return cloud.membership(a.ws);
      case "membersAll": return cloud.memberships();
      case "joined": return cloud.state?.joined ?? [];
      case "unprotected": return cloud.unprotected(a.ws);
      case "rigOf": return cloud.rigOf(a.id, a.ws ?? undefined);
      case "rigs": return cloud.rigs(a.ws);
      case "rigsNamed": return cloud.rigsNamed(a.ws);
      case "rigVouched": return cloud.rigVouched?.(a.ws, a.rig) === true;
      case "movedOffered": return cloud.movedOffered?.has(a.ws) === true;
      case "waiting": return cloud.waiting(a.ws);
      case "answerWays": return answerWays(waysOf(cloud), a.request, a.ws);
      case "answerMarks": return answerMarks(stationMarksOf(cloud), a.request, a.ws);
      case "pinMoved": return false;
      case "peerAsk": if (peerAsk === null) throw new Error("no peer"); return peerAsk(a.station, a.ws, a.request);
    }
    throw new Error(`no keeper part ${fn}`);
  };
}

/// What a function gave or threw, as both sides say it: its value, or its error's words and whether the lock refused.
function outcome(f: () => unknown): unknown {
  try {
    return { ok: f() };
  } catch (e) {
    return { error: (e as Error).message, lock: e instanceof LockRefusal };
  }
}

const NOW_MS = 1_700_000_000_000;
mock.method(wall, "now", () => NOW_MS);

/// One harness for the admission's cases, its clock and floors the TypeScript's.
let admitting: Harness | null = null;
after(() => admitting?.close());
async function admissionHarness(): Promise<Harness> {
  if (admitting !== null) return admitting;
  const h = new Harness(binary!);
  await h.ready;
  await h.tell({ op: "now", secs: Math.floor(NOW_MS / 1000) });
  await h.tell({ op: "floors", floors: { oldest_core: OLDEST_CORE, counted_from: COUNTED_FROM, moved_from: MOVED_FROM_BUILD, root_out_from: ROOT_OUT_FROM_BUILD, logs_before: LOGS_BEFORE, logs_any_from: LOGS_ANY_FROM_BUILD } });
  admitting = h;
  return h;
}

/// A case: the TypeScript's outcome on one station, the program's on another made the same, each with what it then
/// keeps (`after`, read of each station once its case ran: what it took must be the same too).
async function sameOn(make: () => Cloud, fn: string, args: Record<string, unknown>, ts: (c: Cloud) => unknown, afterwards: (c: Cloud) => unknown = () => null) {
  const h = await admissionHarness();
  const mine = make();
  const expected = outcome(() => ts(mine));
  const kept = afterwards(mine);
  const theirs = make();
  h.keeper = keeperOf(theirs);
  const said = await h.call(fn, { args });
  const got = "error" in said ? { error: said.error, lock: said.lock } : { ok: said.ok };
  assert.deepEqual(got, JSON.parse(JSON.stringify(expected)), `${fn} ${JSON.stringify(args).slice(0, 200)}`);
  assert.deepEqual(JSON.parse(JSON.stringify(afterwards(theirs) ?? null)), JSON.parse(JSON.stringify(kept ?? null)), `${fn}: what the station kept after`);
  assert.deepEqual(h.defects, []);
}

import { WS as MWS, bring, dev, ed, handover, signed, station, viewerOf, world } from "./lock-moved-world.ts";
import { entryHash } from "../src/cloud/lock.ts";

const admittedOf = (viewer: ReturnType<typeof viewerOf>) => ({ viewer, exp: 4102444800, iat: 1000, sid: "sid" });

test("the lock lets in, lowers and refuses as the TypeScript does, on a lock not moved", { skip }, async () => {
  const w = world();
  const make = () => station(w, 0, false);
  const carol = viewerOf("carol", w.carol.app, "owner");
  const stranger = viewerOf("carol", dev(), "owner");
  const lockOf = (c: Cloud) => [c.lockAfter(-1, null).map(hashOf), [...personChainsOf(c).every()].map(([g, e]) => [g, e.length])];
  await sameOn(make, "inLock", { admitted: admittedOf(carol), named: "owner", endpoint: carol.device }, (c) => inLock(c, admittedOf(carol) as never, "owner", carol.device));
  await sameOn(make, "inLock", { admitted: admittedOf(carol), named: "viewer", endpoint: carol.device }, (c) => inLock(c, admittedOf(carol) as never, "viewer", carol.device));
  await sameOn(make, "inLock", { admitted: admittedOf(stranger), named: "owner", endpoint: stranger.device }, (c) => inLock(c, admittedOf(stranger) as never, "owner", stranger.device));
  await sameOn(make, "stillIn", { admitted: admittedOf(carol), named: "admin", endpoint: carol.device }, (c) => stillIn(c, admittedOf(carol) as never, "admin", carol.device));
  // A device of carol's the station has not heard of, bringing the entry that put it in (signed by her own device).
  const phone = dev();
  const brought = signed({ v: 1, ws: w.ws, seq: 1, prev: entryHash(w.first), at: 1000, kind: "device", body: { id: phone.base.hex, sub: "carol", kind: "app", label: "phone", sign_key: phone.signer.id } }, w.carol.app.signer);
  const onPhone = viewerOf("carol", phone, "member");
  const hello = { lock: { device: phone.base.hex, proof: onPhone.lockDevice.proof, entries: [brought] } };
  await sameOn(make, "inLockBringing", { admitted: admittedOf(onPhone), named: "member", endpoint: onPhone.device, hello }, (c) => inLockBringing(c, admittedOf(onPhone) as never, "member", onPhone.device, hello), lockOf);
  await sameOn(make, "inLockBringing", { admitted: admittedOf(onPhone), named: "member", endpoint: onPhone.device, hello: { lock: { ...hello.lock, entries: [] } } }, (c) => inLockBringing(c, admittedOf(onPhone) as never, "member", onPhone.device, { lock: { ...hello.lock, entries: [] } }), lockOf);
  // A refusal: the lock's head, the workspace's last entries, carol's chains kept here.
  const refusedHello = { credential: `x.${Buffer.from(JSON.stringify({ ws: w.ws })).toString("base64url")}.y`, lock: { device: phone.base.hex, proof: onPhone.lockDevice.proof } };
  await sameOn(make, "refusalOf", { hello: refusedHello, device: onPhone.device, error: { lock: true, message: "not in the lock" }, sub: "carol" }, (c) => refusalOf(c, refusedHello, onPhone.device, new LockRefusal("not in the lock"), undefined, "carol"));
  await sameOn(make, "refusalOf", { hello: refusedHello, device: onPhone.device, error: { message: "credential expired" }, sub: null }, (c) => refusalOf(c, refusedHello, onPhone.device, new Error("credential expired"), undefined, null));
  await sameOn(make, "movedFloor", { workspace: w.ws }, (c) => movedFloor(c, w.ws));
});

test("the lock's routes answer as the TypeScript does, on a lock not moved", { skip }, async () => {
  const w = world();
  const make = () => station(w, 0, false);
  const alice = viewerOf("alice", w.alice.app, "owner");
  const carol = viewerOf("carol", w.carol.app, "member");
  const route = (viewer: unknown, method: string, query: [string, string][], body: string) =>
    sameOn(make, "lockRoute", { viewer, method, query, body }, (c) => lockRoute(c, method, query, Buffer.from(body), viewer as never), (c) => c.lockAfter(-1, null).map(hashOf));
  await route(carol, "GET", [], "");
  await route(carol, "GET", [["after", "0"]], "");
  await route(carol, "GET", [["after", "x"]], "");
  await route(carol, "PUT", [], "");
  await route(carol, "POST", [], "{not json");
  await route(carol, "POST", [], "{}");
  await route(carol, "POST", [], JSON.stringify({ entries: [{ v: 2 }] }));
  const phone = dev();
  const entry = signed({ v: 1, ws: w.ws, seq: 1, prev: entryHash(w.first), at: 1000, kind: "device", body: { id: phone.base.hex, sub: "carol", kind: "app", label: "phone", sign_key: phone.signer.id } }, w.carol.app.signer);
  await route(carol, "POST", [], JSON.stringify({ entries: [entry] }));
  await route(carol, "POST", [], JSON.stringify({ entries: [entry], keep: true }));
  // One that does not go on from the head: a fork.
  const stale = signed({ v: 1, ws: w.ws, seq: 3, prev: entryHash(w.first), at: 1000, kind: "device", body: { id: dev().base.hex, sub: "carol", kind: "app", label: "x" } }, w.carol.app.signer);
  await route(alice, "POST", [], JSON.stringify({ entries: [stale] }));
  // Someone else's device put in by a member: refused by the rules.
  const bobs = signed({ v: 1, ws: w.ws, seq: 1, prev: entryHash(w.first), at: 1000, kind: "device", body: { id: dev().base.hex, sub: "bob", kind: "app", label: "x" } }, w.carol.app.signer);
  await route(carol, "POST", [], JSON.stringify({ entries: [bobs] }));
  await route(carol, "POST", [], JSON.stringify({ person: w.carol.entries }));
  const part = (viewer: unknown, partName: string, method: string, body: string) =>
    sameOn(make, "lockPartRoute", { viewer, part: partName, method, body }, (c) => lockPartRoute(c, partName, method, Buffer.from(body), viewer as never), (c) => [...personChainsOf(c).every()].map(([g, e]) => [g, e.map(hashOf)]));
  for (const p of ["person", "bodies", "logs", "heads", "nothing"]) await part(carol, p, "GET", "");
  await part(carol, "person", "POST", JSON.stringify({ chain: w.carol.entries }));
  await part(carol, "person", "POST", JSON.stringify({ chain: w.bob.entries }));
  await part(carol, "person", "POST", "{");
  await part(carol, "given", "POST", JSON.stringify({ logs: [w.carol.genesis], bodies: ["x"] }));
  await part(carol, "given", "GET", "");
  await part(carol, "bodies", "POST", JSON.stringify({ bodies: [{}] }));
  await part(carol, "bodies", "POST", JSON.stringify({ nope: 1 }));
  await sameOn(make, "waysRoute", { viewer: carol, method: "GET", body: "" }, (c) => waysRoute(c, "GET", Buffer.alloc(0), carol as never));
  await sameOn(make, "waysRoute", { viewer: { ...carol, role: "viewer" }, method: "POST", body: "{}" }, (c) => waysRoute(c, "POST", Buffer.from("{}"), { ...carol, role: "viewer" } as never));
  await sameOn(make, "waysRoute", { viewer: carol, method: "POST", body: "{}" }, (c) => waysRoute(c, "POST", Buffer.from("{}"), carol as never));
  await sameOn(make, "stationMarksRoute", { viewer: carol, method: "GET", body: "", own: false }, (c) => stationMarksRoute(c, "GET", Buffer.alloc(0), carol as never, false));
  await sameOn(make, "stationMarksRoute", { viewer: carol, method: "PUT", body: "{}", own: true }, (c) => stationMarksRoute(c, "PUT", Buffer.from("{}"), carol as never, true));
  await sameOn(make, "stationMarksRoute", { viewer: alice, method: "PUT", body: "[1]", own: true }, (c) => stationMarksRoute(c, "PUT", Buffer.from("[1]"), alice as never, true));
});

test("a moved workspace: waiting, then its state in force, let in and routed as the TypeScript does", { skip }, async () => {
  const w = world();
  handover(w);
  const waiting = () => station(w);
  const carol = viewerOf("carol", w.carol.app, "member");
  const alice = viewerOf("alice", w.alice.app, "owner");
  await sameOn(waiting, "inLock", { admitted: admittedOf(carol), named: "member", endpoint: carol.device }, (c) => inLock(c, admittedOf(carol) as never, "member", carol.device));
  // What a hello brings of the state: the root's log and its bodies.
  const hello = { lock: { device: w.alice.app.base.hex, proof: alice.lockDevice.proof, person: w.alice.entries, bodies: [...w.alice.bodies.values()] } };
  await sameOn(waiting, "inLockBringing", { admitted: admittedOf(alice), named: "owner", endpoint: alice.device, hello }, (c) => inLockBringing(c, admittedOf(alice) as never, "owner", alice.device, hello), (c) => [[...personChainsOf(c).every()].map(([g, e]) => [g, e.length]), [...c.bodies(null).all().keys()]]);
  const full = () => {
    const c = station(w);
    for (const l of [w.alice, w.bob, w.carol]) bring(c, l);
    return c;
  };
  for (const [v, named] of [[carol, "owner"], [alice, "owner"], [viewerOf("bob", w.bob.app, "admin"), "admin"], [viewerOf("carol", dev(), "member"), "member"]] as const) {
    await sameOn(full, "inLock", { admitted: admittedOf(v), named, endpoint: v.device }, (c) => inLock(c, admittedOf(v) as never, named, v.device));
    await sameOn(full, "inLockBringing", { admitted: admittedOf(v), named, endpoint: v.device, hello: { lock: { person: w.carol.entries } } }, (c) => inLockBringing(c, admittedOf(v) as never, named, v.device, { lock: { person: w.carol.entries } }));
    await sameOn(full, "stillIn", { admitted: admittedOf(v), named, endpoint: v.device }, (c) => stillIn(c, admittedOf(v) as never, named, v.device));
  }
  await sameOn(full, "ownChainsOf", { sub: "alice", workspace: MWS }, (c) => ownChainsOf(c, "alice", MWS));
  await sameOn(full, "movedFloor", { workspace: MWS }, (c) => movedFloor(c, MWS));
  const stranger = viewerOf("dave", dev(), "member");
  const strangerHello = { credential: `x.${Buffer.from(JSON.stringify({ ws: MWS })).toString("base64url")}.y`, lock: { device: stranger.lockDevice.base, proof: stranger.lockDevice.proof } };
  await sameOn(full, "refusalOf", { hello: strangerHello, device: stranger.device, error: { lock: true, message: "not named" }, sub: "carol" }, (c) => refusalOf(c, strangerHello, stranger.device, new LockRefusal("not named"), undefined, "carol"));
  for (const p of ["person", "bodies", "logs", "heads", "devices"]) {
    await sameOn(full, "lockPartRoute", { viewer: carol, part: p, method: "GET", body: "" }, (c) => lockPartRoute(c, p, "GET", Buffer.alloc(0), carol as never));
    await sameOn(full, "lockPartRoute", { viewer: stranger, part: p, method: "GET", body: "" }, (c) => lockPartRoute(c, p, "GET", Buffer.alloc(0), stranger as never));
  }
  await sameOn(full, "lockPartRoute", { viewer: carol, part: "given", method: "POST", body: JSON.stringify({ logs: [w.alice.genesis, "zz"], bodies: [...w.alice.bodies.keys(), "zz"] }) }, (c) => lockPartRoute(c, "given", "POST", Buffer.from(JSON.stringify({ logs: [w.alice.genesis, "zz"], bodies: [...w.alice.bodies.keys(), "zz"] })), carol as never));
  await sameOn(full, "lockRoute", { viewer: carol, method: "GET", query: [["after", "0"]], body: "" }, (c) => lockRoute(c, "GET", [["after", "0"]], Buffer.alloc(0), carol as never));
  void ed;
});

test("small pure parts: builds said, routes, reads, queries, roles", { skip }, async () => {
  const h = await admissionHarness();
  const cases: [string, Record<string, unknown>, unknown][] = [];
  const { buildOf } = await import("../src/api/oldest.ts");
  const { route } = await import("../src/mesh/traces.ts");
  const { queryPairs } = await import("../src/api/request.ts");
  const { lowerRole } = await import("../src/cloud/lock.ts");
  for (const said of ["9144", "0.1.9144", " 0.3.12 ", "1.2.3", "", "x9", "0.1.", "00042"]) cases.push(["buildOf", { said }, buildOf(said)]);
  for (const path of ["/sessions/abc/threads/x?y", "/lock", "/chats/01HZZ/notes#frag", "/a/B/c-d_e.f", "/stations/s1/x", "/" + "a".repeat(30)]) cases.push(["route", { path }, route(path)]);
  for (const q of ["a=1&b=%E4%BD%A0+x", "a&&=b", "x=%zz%2", "k=%2B%20"]) cases.push(["queryPairs", { query: q }, queryPairs(q)]);
  for (const [a, b] of [["owner", "admin"], ["viewer", "owner"], ["nope", "admin"], ["member", "member"]]) cases.push(["lowerRole", { a, b }, lowerRole(a!, b!)]);
  for (const [fn, args, expected] of cases) {
    const said = await h.call(fn, { args });
    assert.deepEqual(said.ok, expected, `${fn} ${JSON.stringify(args)}`);
  }
});

// Storms, connections superseded and the devices seen (storms.ts, superseded.ts, seen-devices.ts), on scripts both
// sides run: what each closes, says and keeps.
import { Storms } from "../src/mesh/storms.ts";
import { Superseded } from "../src/mesh/superseded.ts";
import { SeenDevices } from "../src/mesh/seen-devices.ts";
import { hearLines } from "../src/ops/log.ts";
import { readFileSync, writeFileSync } from "node:fs";

/// A connection of the script's (calls.mbt `scripted`): its stats as the script says, whether it answers.
function scriptedConn(id: string, stats: { now: any }, answers: boolean, closes: unknown[], name: string): Connection {
  let closed = false;
  let resolve!: (r: string) => void;
  const done = new Promise<string>((r) => (resolve = r));
  return {
    remoteId: () => id, alpn: () => Buffer.alloc(0), via: () => null,
    paths: () => [{ selected: true, ip: "10.0.0.1:1", relay: null, rttMs: 12.4, txPackets: 3, lostPackets: 0 }],
    acceptBi: async () => null, openBi: async () => { throw new Error("none"); },
    answers: async () => answers,
    ...(stats.now === null ? {} : { stats: () => stats.now }),
    close: (code: number, reason: string) => {
      if (closed) return;
      closed = true;
      closes.push({ conn: name, code, reason });
      resolve(reason);
    },
    isClosed: () => closed,
    closed: () => done,
  } as Connection;
}

const heard = (f: () => unknown) => {
  const said: unknown[] = [];
  hearLines((l) => void said.push([String(l.level).toLowerCase(), l.message, l.fields]));
  return Promise.resolve(f()).then((out) => {
    hearLines(null);
    return { out, said };
  });
};

test("storms are found, said and closed as the TypeScript does", { skip }, async () => {
  const h = await admissionHarness();
  const quiet = { rxPackets: 0, txPackets: 0, rxData: 0, txData: 0, rxPings: 0, txPings: 0, rxAckRequests: 0, txAckRequests: 0, rxAcks: 0, txAcks: 0 };
  const grow = (n: number, data = 0) => ({ ...quiet, rxPackets: n, txPackets: n, rxAcks: n, txAcks: n, rxData: data, txData: data });
  const conns = [
    { id: "a".repeat(64), first: quiet },
    { id: "b".repeat(64), first: quiet },
    { id: "c".repeat(64), first: null },
    { id: "d".repeat(64), first: { rxBytes: 1, txBytes: 2 } },
  ];
  // a storms for 12 s; b storms 3 s, calms, storms again with data; each look a second apart, one 1.5 s and one 0.4 s.
  const looks: { at: number; stats: unknown[] }[] = [];
  let at = 0;
  for (let i = 1; i <= 14; i++) {
    at += i === 5 ? 1500 : i === 9 ? 400 : 1000;
    const b = i <= 3 ? grow(i * 2000) : i <= 6 ? grow(6000 + i) : grow(6000 + i * 3000, i * 100);
    looks.push({ at, stats: [grow(i * 5000), b, null, { rxBytes: 1, txBytes: 2 }] });
  }
  const script = { conns, looks };
  const { out: expected, said } = await heard(() => {
    let now = 0;
    const storms = new Storms({ now: () => now, every: () => () => {} } as never);
    const closes: unknown[] = [];
    const refs = conns.map((c) => ({ now: c.first }));
    conns.forEach((c, i) => storms.watch(scriptedConn(c.id, refs[i]!, true, closes, c.id)));
    const watched = (storms as any)["#watched"]?.size;
    void watched;
    for (const look of looks) {
      now = look.at;
      look.stats.forEach((s, i) => (refs[i]!.now = s as never));
      storms.look();
    }
    return closes;
  });
  const got = await h.call("storms", { args: script });
  assert.deepEqual(got.ok.closes, expected);
  assert.deepEqual(got.ok.said, JSON.parse(JSON.stringify(said)));
  assert.equal(got.ok.watched, 2, "watched only where packets are counted");
});

test("a device's older connections are asked, and those gone closed, as the TypeScript does", { skip }, async () => {
  const h = await admissionHarness();
  const id = "e".repeat(64), other = "f".repeat(64);
  const arrive = [
    { id, name: "e1", answers: false },
    { id, name: "e2", answers: true },
    { id: other, name: "f1", answers: false },
    { id, name: "e3", answers: true },
    { id: other, name: "f2", answers: true, closeBefore: 2 },
    { id, name: "e4", answers: true },
  ];
  const { out: expected, said } = await heard(async () => {
    const sup = new Superseded();
    const closes: unknown[] = [];
    const made: Connection[] = [];
    for (const a of arrive) {
      const conn = scriptedConn(a.id, { now: null }, a.answers, closes, a.name);
      made.push(conn);
      if (a.closeBefore !== undefined) made[a.closeBefore]!.close(0, "done");
      await sup.arrived(conn);
    }
    await new Promise((r) => setImmediate(r));
    const open = Object.fromEntries([...new Set(arrive.map((a) => a.id))].map((i) => [i, (sup as any)["#open"]?.get(i)?.size ?? 0]));
    void open;
    return closes;
  });
  const got = await h.call("superseded", { args: { arrive } });
  assert.deepEqual(got.ok.closes, expected);
  assert.deepEqual(got.ok.said, JSON.parse(JSON.stringify(said)));
});

test("the devices seen are kept, read and written as the TypeScript does", { skip }, async () => {
  const h = await admissionHarness();
  const day = 86400;
  const steps: Record<string, unknown>[] = [
    { saw: true, at: 1000, workspace: "w", sub: "alice", email: "a@x", device: "d1", base: "b1", said: { kind: "app", label: "Alice's phone" } },
    { saw: true, at: 1500, workspace: "w", sub: "alice", email: "a@x", device: "d1", base: null, said: null },
    { saw: true, at: 1000 + 3600, workspace: "w", sub: "alice", email: "a@x", device: "d1", base: null, said: { kind: "nope", label: "x".repeat(200) } },
    { saw: true, at: 2000, workspace: "w", sub: "bob", email: "b@x", device: "d2", base: null, said: { kind: "web" } },
    { saw: true, at: 2100, workspace: "v", sub: "bob", email: "b@x", device: "d3", base: "b3", said: {} },
    { saw: true, at: 2200, workspace: "w", sub: "alice", email: "a2@x", device: "d4", base: null, said: null },
    { at: 5000, workspace: "w", sub: "bob", manages: false },
    { at: 5000, workspace: "w", sub: "bob", manages: true },
    { saw: true, at: 40 * day, workspace: "w", sub: "carol", email: "c@x", device: "d5", base: null, said: null },
    { at: 40 * day, workspace: "w", sub: "x", manages: true },
  ];
  const dir = mkdtempSync(join(tmpdir(), "seen-"));
  after(() => rmSync(dir, { recursive: true, force: true }));
  const kept = JSON.stringify([{ workspace: "w", sub: "zed", email: "z@x", device: "d0", base: null, kind: null, label: null, first_seen: 900, last_seen: 900 }, { bad: 1 }]);
  writeFileSync(join(dir, "seen.json"), kept);
  const seen = new SeenDevices(join(dir, "seen.json"));
  const reads: unknown[] = [];
  for (const s of steps) {
    if (s.saw) seen.saw(s.at as number, { workspace: s.workspace as string, sub: s.sub as string, email: s.email as string }, s.device as string, s.base as string | null, s.said);
    else reads.push(seen.of(s.workspace as string, s.at as number, s.sub as string, s.manages as boolean));
  }
  await seen.written();
  const got = await h.call("seen", { args: { kept, steps } });
  assert.deepEqual(got.ok.reads, reads);
  assert.deepEqual(got.ok.written, JSON.parse(readFileSync(join(dir, "seen.json"), "utf8")));
});

// A member's connection whole (serve.ts `serve`): a credential the control plane signed, the lock, renewals, the
// lock's and the admin API's routes, compression, an old core told to update, refusals and their closes; the client
// in TypeScript, the station in each language on stations made the same.
import { GrantKey } from "./fake-control-plane.ts";
import { Cloud as CloudOf, writeState } from "../src/cloud/state.ts";
import { type Members, serve as serveMember } from "../src/mesh/serve.ts";
import { endpointBytes } from "../src/cloud/lock.ts";
import { tr } from "../src/ops/i18n.ts";

const WSM = "01HMEMBERMEMBERMEMBERMEMBE";

function memberWorld() {
  const grant = new GrantKey("k1");
  const alice = { signer: ed(), base: ed() }, carol = { signer: ed(), base: ed() };
  const stations = [ed(), ed()];
  const body = {
    owner: "alice", origins: ["https://app.still.fail"], rp_id: "app.still.fail", cloud_keys: { keys: [grant.jwk] },
    members: [{ sub: "alice", email: "a@x", role: "owner" }, { sub: "carol", email: "c@x", role: "member" }],
    devices: [["alice", alice], ["carol", carol]].map(([sub, p]: any) => ({ id: p.base.hex, sub, kind: "app", label: sub, sign_key: p.signer.id })),
    passkeys: [], stations: stations.map((s, i) => ({ key: s.hex, name: `s${i}` })), gateways: [],
  };
  const first = signed({ v: 1, ws: WSM, seq: 0, prev: null, at: 1000, kind: "genesis", body }, alice.signer);
  const make = () => {
    const data = mkdtempSync(join(tmpdir(), "member-"));
    writeState(data, {
      origin: "https://app.still.fail", station: stations[0]!.hex, workspace: WSM, workspace_name: "Team", name: "s0", relay_url: "", relay_urls: [],
      grant_keys: { keys: [grant.jwk] }, peers: stations.map((s, i) => ({ id: s.hex, name: `s${i}` })), revocations: [],
    });
    const c = new CloudOf(data);
    c.takeLock([first]);
    return c;
  };
  const credential = (device: string, role: string, sub = "carol") =>
    grant.credential({ typ: "stillfail-member+jwt" }, { iss: "stillfail-cloud", sub, email: `${sub}@x`, name: sub, ws: WSM, role, device, sid: "sid", iat: 1000, exp: Math.floor(NOW_MS / 1000) + 3600 });
  return { grant, alice, carol, make, credential };
}

/// The admin API of the member scenario (calls.mbt `echo_admin`, word for word).
const echoAdmin = {
  readers: { names: new Map<string, string>() },
  handle: async (ask: any): Promise<Answer> => {
    const big = Number(ask.query.find(([k]: [string, string]) => k === "big")?.[1] ?? 0) || 0;
    const said = { method: ask.method, path: ask.path, query: ask.query, search: ask.search, headers: ask.headers, body: ask.body.toString(), viewer: ask.viewer, lang: ask.lang, items: Array.from({ length: big }, (_, i) => `item ${i} said again and again`) };
    return { status: 200, headers: { "content-type": "application/json" }, body: Buffer.from(JSON.stringify(said)) };
  },
};

/// The member client: what it heard, in order.
async function memberClient(conn: Connection, hello: unknown, renewals: unknown[], advance: () => Promise<void>, closedOf: () => Closed): Promise<unknown[]> {
  const said: unknown[] = [];
  const control = await conn.openBi();
  const r = new Reader(control, 64 * 1024);
  await writeLine(control, hello);
  said.push(await r.line());
  if ((said[0] as any)?.ok !== true) {
    await advance();
    await conn.closed().catch(() => {});
    said.push(closedOf());
    return said;
  }
  const ask = async (method: string, path: string, headers: Record<string, string> = {}, body = "") => {
    const s = await conn.openBi();
    await writeLine(s, { method, path, headers });
    if (body !== "") await s.write(Buffer.from(body));
    await s.finish();
    const rr = new Reader(s);
    const head = await rr.line();
    const got = await rr.rest();
    const plain = head?.headers?.["content-encoding"] === "zstd" ? zstdDecompressSync(got, { finishFlush: constants.ZSTD_e_flush }) : got;
    let parsed: unknown = plain.toString();
    try { parsed = JSON.parse(plain.toString()); } catch {}
    return { head, body: parsed };
  };
  said.push(...(await Promise.all([
    ask("GET", "/admin/api/lock"),
    ask("GET", "/admin/api/ways"),
    ask("GET", "/admin/api/things?big=40&x=%E4%BD%A0+y", { "accept-encoding": "zstd", "stillfail-lang": "en", "x-stillfail-secret": "s", "content-length": "9" }),
    ask("post", "/admin/api/echo", { "content-type": "text/plain" }, "hello"),
    ask("GET", "/nope"),
    ask("GET", "/admin/api/../x"),
    ask("GET", "/admin/api/x", { "stillfail-build": "1500" }),
    ask("GET", "/admin/api/lock/devices"),
    ask("GET", "/admin/api/lock/person"),
    ask("POST", "/admin/api/lock", {}, "{}"),
  ])));
  for (const line of renewals) {
    await writeLine(control, line);
    said.push(await r.line());
    said.push(await ask("GET", "/admin/api/who"));
  }
  return said;
}

test("a member's connection: let in, renewed, routed, refused, as the TypeScript serves it", { skip }, async () => {
  const w = memberWorld();
  const mesh = memoryMesh();
  const alpn = Buffer.from("stillfail/admin/1");
  const h = await admissionHarness();
  const words = { zh: tr("zh", "station.admin.updateApp"), en: tr("en", "station.admin.updateApp") };
  const run = async (hello: (device: string) => unknown, renewals: (device: string) => unknown[]) => {
    // TypeScript: what is to be heard.
    timers.length = 0;
    const bind = () => mesh.bind({ secretKey: randomBytes(32), alpns: [alpn], relayUrls: [], discovery: false });
    const [at, devEnd] = await Promise.all([bind(), bind()]);
    after(() => Promise.all([at.close(), devEnd.close()]));
    const device = devEnd.id();
    const [client, server] = await Promise.all([devEnd.connect({ id: at.id() }, alpn), at.accept()]);
    let rec: Closed = { closed: false };
    const close = server!.close.bind(server);
    server!.close = (code, reason) => {
      if (!rec.closed) rec = { closed: true, by_peer: true, code, reason };
      close(code, reason);
    };
    const m = { cloud: w.make(), admin: echoAdmin, up: () => true, tailnet: () => ["100.64.0.9:7"] } as unknown as Members;
    void serveMember(m, server!).catch(() => {}).finally(() => server!.close(0, "served"));
    const expected = await memberClient(client, hello(device), renewals(device), async () => fireTimers(), () => rec);
    client.close(0, "done");
    // The program, on a station made the same.
    h.keeper = keeperOf(w.make());
    const id = ++nextConn;
    const conn = new FarConn(h, id, "mb");
    await h.tell({ op: "conn", conn: id, role: "member", here: "mb", remote: device, update: words });
    const heard = await memberClient(conn, hello(device), renewals(device), () => h.tell({ op: "advance", ms: 200 }), () => ({ ...conn.closedRec, by_peer: true }));
    conn.close(0, "done");
    assert.deepEqual(heard, JSON.parse(JSON.stringify(expected)));
    assert.deepEqual(h.defects, []);
  };
  const proofOf = (device: string) => ({ device: w.carol.base.hex, proof: w.carol.base.sign(endpointBytes(WSM, device)), kind: "app", label: "carol's phone" });
  // carol on her own device, the control plane saying owner: let in as the member the lock says.
  await run((d) => ({ credential: w.credential(d, "owner"), lock: proofOf(d), traceparent: "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01" }), (d) => [
    { credential: w.credential(d, "viewer") },
    // (one whose head is no JSON at all: TypeScript says JSON.parse's own words, V8's, the program "malformed
    // credential"; a refusal's words alone, and not held here)
    { credential: "a.b" },
    { credential: w.credential(d, "admin", "alice") },
  ]);
  // A device the lock does not name: refused for the lock, told its head and carol's chains here.
  await run((d) => ({ credential: w.credential(d, "owner") }), () => []);
  // A credential for another device: refused as a credential.
  await run(() => ({ credential: w.credential("f".repeat(64), "owner"), lock: proofOf("f".repeat(64)) }), () => []);
  await run(() => ({ nothing: true }), () => []);
});

// The station transport (peer.ts `peerCall`, `servePeer`) both ways, and the lock's and person logs' sync
// (lock-sync.ts, person-sync.ts): a TypeScript station asking a MoonBit one and the other way round, each transcript the
// one two TypeScript stations make; the program's sync with a TypeScript station leaving both as two TypeScript ones do.
import { PEER_ALPN, PEER_BYTES_ALPN, peerCall, servePeer, member as tsMember, roster as tsRoster, heardWaiting as tsHeardWaiting } from "../src/mesh/peer.ts";
import { BYTES, PeerBus, Refused as PeerRefusedTs, withBytes } from "../src/mesh/bus.ts";
import { answerLock, syncWith } from "../src/mesh/lock-sync.ts";
import { bodiesSyncWith, personSyncWith } from "../src/mesh/person-sync.ts";

const bytesOfSize = (n: number) => {
  const b = Buffer.alloc(n);
  for (let i = 0; i < n; i++) b[i] = (i * 7) % 251;
  return b;
};
const sumOf = (b: Buffer) => checksum(b);

/// The station transport's bus of the interop (interop.mbt `interop_bus`, word for word).
function interopBus(): PeerBus {
  const bus = new PeerBus({ sleep: () => new Promise(() => {}) });
  bus.otherwise(async (peer, request: any, workspace) => {
    if (request?.method === "fail") throw new Error("refused as asked");
    const parts: Buffer[] = [];
    const came = (request as any)?.[BYTES];
    if (came) for await (const piece of came) parts.push(Buffer.from(piece));
    const got = Buffer.concat(parts);
    const said: any = { asked: JSON.parse(JSON.stringify(request)), peer, workspace, size: got.length, sum: sumOf(got) };
    if (request?.method === "file") {
      const n = request.n as number;
      return withBytes(said, (async function* () {
        const all = bytesOfSize(n);
        for (let at = 0; at < n; at += 65536) yield all.subarray(at, Math.min(at + 65536, n));
      })());
    }
    return said;
  });
  return bus;
}

/// One step of the interop client (interop.mbt `peer_client_step`).
async function peerStep(call: (t: string, ws: string | null, r: any) => Promise<any>, target: string, step: any): Promise<unknown> {
  const request = JSON.parse(JSON.stringify(step.request));
  if (typeof step.bytes === "number") {
    const all = bytesOfSize(step.bytes);
    withBytes(request, (async function* () {
      for (let at = 0; at < all.length; at += 65536) yield all.subarray(at, Math.min(at + 65536, all.length));
    })());
  }
  try {
    const result = await call(step.to ?? target, step.workspace ?? null, request);
    const came = result?.[BYTES];
    if (!came) return { result: JSON.parse(JSON.stringify(result)) };
    const parts: Buffer[] = [];
    for await (const piece of came) parts.push(Buffer.from(piece));
    const got = Buffer.concat(parts);
    return { result: JSON.parse(JSON.stringify(result)), size: got.length, sum: sumOf(got) };
  } catch (e) {
    return { error: (e as Error).message, refused: e instanceof PeerRefusedTs };
  }
}

/// Two stations of one workspace: s0 (`at`) and s1 (`asking`), the one asking dialing from an endpoint of its own key.
async function stationsWorld() {
  const mesh = memoryMesh();
  const secret = randomBytes(32);
  const asker = await mesh.bind({ secretKey: secret, alpns: [PEER_BYTES_ALPN, PEER_ALPN], relayUrls: [], discovery: false });
  const at = await mesh.bind({ secretKey: randomBytes(32), alpns: [PEER_BYTES_ALPN, PEER_ALPN], relayUrls: [], discovery: false });
  after(() => Promise.all([asker.close(), at.close()]));
  const grant = new GrantKey("k1");
  const alice = { signer: ed(), base: ed() };
  const stationIds = [at.id(), asker.id()];
  const body = {
    owner: "alice", origins: ["https://app.still.fail"], rp_id: "app.still.fail", cloud_keys: { keys: [grant.jwk] },
    members: [{ sub: "alice", email: "a@x", role: "owner" }], devices: [{ id: alice.base.hex, sub: "alice", kind: "app", label: "a", sign_key: alice.signer.id }],
    passkeys: [], stations: stationIds.map((s, i) => ({ key: s, name: `s${i}` })), gateways: [],
  };
  const first = signed({ v: 1, ws: WSM, seq: 0, prev: null, at: 1000, kind: "genesis", body }, alice.signer);
  const more = [first];
  for (let i = 1; i <= 3; i++) {
    const d = dev();
    more.push(signed({ v: 1, ws: WSM, seq: i, prev: entryHash(more[i - 1]!), at: 1000, kind: "device", body: { id: d.base.hex, sub: "alice", kind: "app", label: `d${i}`, sign_key: d.signer.id } }, alice.signer));
  }
  /// Station `i` (0 the one asked, 1 the one asking), its lock as far as `seq`.
  const make = (i: number, seq = 0) => {
    const data = mkdtempSync(join(tmpdir(), "peer-"));
    writeState(data, {
      origin: "https://app.still.fail", station: stationIds[i]!, workspace: WSM, workspace_name: "Team", name: `s${i}`, relay_url: "", relay_urls: [],
      grant_keys: { keys: [grant.jwk] }, peers: stationIds.map((s, j) => ({ id: s, name: `s${j}` })), revocations: [],
    });
    const c = new CloudOf(data);
    c.takeLock(more.slice(0, seq + 1));
    return c;
  };
  return { mesh, asker, at, stationIds, make, more };
}

const STEPS = (target: string) => [
  { request: { method: "echo", x: 1 }, workspace: WSM },
  { request: { method: "echo" } },
  { request: { method: "upload" }, workspace: WSM, bytes: 300_000 },
  { request: { method: "file", n: 200_000 }, workspace: WSM },
  { request: { method: "fail" }, workspace: WSM },
  { to: "", request: { method: "peers" }, workspace: WSM },
  { request: { method: "lock.head" }, workspace: WSM },
  { request: { method: "lock.kept" }, workspace: WSM },
  { request: { method: "lock.nope" }, workspace: WSM },
  { to: "f".repeat(64), request: { method: "echo" }, workspace: WSM },
  { request: { method: "echo" }, workspace: "01HOTHERWORKSPACEOTHERWORK" },
  void target,
].filter((x) => x !== undefined);

test("the station transport: a TypeScript station asks a MoonBit one as it asks a TypeScript one, and the other way", { skip }, async () => {
  const w = await stationsWorld();
  const h = await admissionHarness();
  const [s0, s1] = w.stationIds as [string, string];
  // Two TypeScript stations: what is to be heard.
  const tsAt = w.make(0, 1);
  const bus = interopBus();
  void (async () => {
    for (let conn = await w.at.accept(); conn; conn = await w.at.accept()) void servePeer(conn, tsAt, bus).catch(() => {});
  })();
  const tsCall = peerCall(w.asker, w.make(1), (id) => ({ id }));
  const expected: unknown[] = [];
  for (const step of STEPS(s0)) expected.push(await peerStep(tsCall, s0, step));
  tsCall.close?.();

  // A TypeScript station asking the program's (on a station made the same).
  h.keeper = keeperOf(w.make(0, 1));
  const toProgram = { connect: async (_addr: unknown, alpn: Buffer) => {
    const id = ++nextConn;
    const conn = new FarConn(h, id, s0, alpn.toString());
    await h.tell({ op: "conn", conn: id, role: "peer", here: s0, remote: s1, alpn: alpn.toString() });
    return conn;
  } };
  const call = peerCall(toProgram as never, w.make(1), (id) => ({ id }));
  const heard: unknown[] = [];
  for (const step of STEPS(s0)) heard.push(await peerStep(call, s0, step));
  assert.deepEqual(heard, expected);

  // The program asking a TypeScript station.
  h.keeper = keeperOf(w.make(1));
  const asked = w.make(0, 1);
  const id = ++nextConn;
  const conn = new FarConn(h, id, s0, PEER_BYTES_ALPN.toString());
  const result = new Promise<any>((resolve) => {
    conn.onOther = (ev) => {
      if (ev.ev === "result") resolve(ev.said);
      else if (ev.ev === "dial") {
        const dialed = new FarConn(h, ev.dialed, s1, ev.alpn);
        void servePeer(dialed, asked, interopBus()).catch(() => {});
      }
    };
  });
  await h.tell({ op: "conn", conn: id, role: "peerclient", here: s1, remote: s0, calls: STEPS(s0) });
  assert.deepEqual(await result, expected);
  assert.deepEqual(h.defects, []);
  void tsMember; void tsRoster; void tsHeardWaiting;
});

test("the lock and the person logs brought level between a MoonBit station and a TypeScript one, as two TypeScript ones", { skip }, async () => {
  const w = await stationsWorld();
  const h = await admissionHarness();
  const [s0, s1] = w.stationIds as [string, string];
  const state = (c: Cloud) => [c.lockKept(null).map(hashOf), c.chain(null)?.state?.seq ?? null, [...personChainsOf(c).every()].map(([g, e]) => [g, e.map(hashOf)]), [...c.bodies(null).all().keys()]];
  for (const [mine, theirs] of [[1, 3], [3, 1], [2, 2]] as const) {
    // Two TypeScript stations: s1 brought level with s0.
    const a = w.make(1, mine), b = w.make(0, theirs);
    const tsAsk = async (_station: string, ws: string | null, request: any) => answerLock(b, request, ws, s1);
    await syncWith(a, tsAsk as never, s0, null);
    await personSyncWith(personChainsOf(a), tsAsk as never, s0, WSM);
    await bodiesSyncWith(a, tsAsk as never, s0, WSM);
    const expected = [state(a), state(b)];
    // The program as s1, its asks answered by a TypeScript s0.
    const a2 = w.make(1, mine), b2 = w.make(0, theirs);
    h.keeper = keeperOf(a2, (_station, ws, request) => answerLock(b2, request, ws, s1));
    for (const [fn, args] of [["syncWith", { peer: s0, ws: null }], ["personSyncWith", { peer: s0, ws: WSM }], ["bodiesSyncWith", { peer: s0, ws: WSM }]] as const) {
      const said = await h.call(fn, { args });
      assert.equal(said.error, undefined, `${fn}: ${said.error}`);
    }
    assert.deepEqual([state(a2), state(b2)], expected, `level, ${mine} against ${theirs}`);
  }
  // The answers themselves, of each kind.
  const asked = () => w.make(0, 2);
  for (const request of [{ method: "lock.head" }, { method: "lock.kept" }, { method: "lock.get", after: 0 }, { method: "lock.get", hashes: [hashOf(w.more[1]!), "x"] }, { method: "lock.put", entries: [w.more[3]] }, { method: "lock.offer", entries: [w.more[3]] }, { method: "lock.offer", entries: [{ v: 9 }] }, { method: "lock.person.heads" }, { method: "lock.person.kept" }, { method: "lock.person.get", genesis: "x" }, { method: "lock.bodies.kept" }, { method: "lock.bodies.get", hashes: ["x"] }, { method: "lock.bodies.offer", bodies: [] }, { method: "lock.what" }]) {
    await sameOn(asked, "answerLock", { request, workspace: null, peer: s1 }, (c) => answerLock(c, request, null, s1), (c) => c.lockKept(null).map(hashOf));
  }
  await sameOn(asked, "member", { peer: s1, workspace: null }, (c) => tsMember(c, s1, null));
  await sameOn(asked, "member", { peer: s0, workspace: null }, (c) => tsMember(c, s0, null));
  await sameOn(asked, "member", { peer: "a".repeat(64), workspace: WSM }, (c) => tsMember(c, "a".repeat(64), WSM));
  await sameOn(asked, "roster", { workspace: null }, (c) => tsRoster(c, null));
  await sameOn(asked, "roster", { workspace: "nope" }, (c) => tsRoster(c, "nope"));
  for (const m of ["lock.head", "rig.added", "echo", 5]) await sameOn(asked, "heardWaiting", { method: m }, (c) => tsHeardWaiting(c, m));
});

// Web requests and forwarded connections between stations (peer-http.ts): a TypeScript station's tunnels to a MoonBit
// one answered as a TypeScript one answers them (interop.mbt `interop_here`, and its twin here).
import { connect, createServer } from "node:net";
import { HttpRefusal, PEER_HTTP_ALPN, PeerHttp, serveHttp } from "../src/mesh/peer-http.ts";
import { ownPorts } from "../src/ops/own.ts";

test("forwarded connections and their refusals: a MoonBit station answers a TypeScript one's tunnels as a TypeScript one does", { skip }, async () => {
  const w = await stationsWorld();
  const h = await admissionHarness();
  const [s0, s1] = w.stationIds as [string, string];
  ownPorts.add(4242);
  after(() => ownPorts.delete(4242));
  // Port 5000 "there": a service on a port of this machine's that greets and ends, reached as reachLocal reaches one.
  const service = createServer({ allowHalfOpen: true }, (sock) => sock.end("greetings from 5000"));
  await new Promise<void>((r) => service.listen(0, "127.0.0.1", r));
  after(() => service.close());
  const servicePort = (service.address() as { port: number }).port;
  const here = {
    reach: async (port: number) => {
      if (port !== 5000) throw new Error(`connect ECONNREFUSED 127.0.0.1:${port}`);
      return await new Promise<never>((resolve, reject) => {
        const socket = connect({ host: "127.0.0.1", port: servicePort, allowHalfOpen: true });
        socket.once("error", reject);
        socket.once("connect", () => {
          socket.pause();
          resolve(socket as never);
        });
      });
    },
    forwarded: (port: number) => port === 4343,
  };
  const tries = async (http: PeerHttp) => {
    const out: unknown[] = [];
    for (const [given, port, probe] of [[s0, 5000, true], [s0, 5000, false], [s0, 4242, false], [s0, 4343, true], [s0, 7, false], [s0, 0, false], [s0, 70000, true], ["nobody", 5000, true], [s1, 5000, true]] as const) {
      try {
        const t = await http.tunnel(given, port, probe);
        if (t === null) out.push({ probed: true });
        else {
          await t.stream.finish();
          const parts = [t.carry];
          for (let more = await t.stream.read(); more !== null; more = await t.stream.read()) parts.push(more);
          out.push({ echo: Buffer.concat(parts).toString() });
        }
      } catch (e) {
        out.push(e instanceof HttpRefusal ? { status: e.status, error: e.message, unreachable: e.unreachable } : { error: (e as Error).message });
      }
    }
    return out;
  };
  // Two TypeScript stations.
  const tsAt = w.make(0, 1);
  const tsEnd = { connect: async () => {
    const pair = await tsPair();
    Object.defineProperty(pair.client, "alpn", { value: () => PEER_HTTP_ALPN });
    Object.defineProperty(pair.client, "remoteId", { value: () => s0 });
    Object.defineProperty(pair.server, "remoteId", { value: () => s1 });
    void serveHttp(pair.server, tsAt, here).catch(() => {});
    return pair.client;
  } };
  const expected = await tries(new PeerHttp(tsEnd as never, w.make(1), (id) => ({ id })));
  // The asker the same, the station asked the program's.
  h.keeper = keeperOf(w.make(0, 1));
  const toProgram = { connect: async () => {
    const id = ++nextConn;
    const conn = new FarConn(h, id, s0, PEER_HTTP_ALPN.toString());
    await h.tell({ op: "conn", conn: id, role: "http", here: s0, remote: s1 });
    return conn;
  } };
  const heard = await tries(new PeerHttp(toProgram as never, w.make(1), (id) => ({ id })));
  assert.deepEqual(heard, expected);
  assert.deepEqual(h.defects, []);
});
