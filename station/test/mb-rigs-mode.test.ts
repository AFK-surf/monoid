// The rigs in MoonBit (station/mb src/rigs_mode, `stillfail-reader-harness --builder harness-rigs-mode`) held to the TypeScript it
// is written from: src/rig (a rig's grants, its command log, what it answers and tells the stations), src/rigs (the
// workspace's rigs on a station: the outbox, the requests and their cards, security mode's adds, station_use,
// station_list's and the devices' rows, the routes) and src/elevation (running as administrator, its scripts and
// route). Each case is a script run once on the TypeScript and once on the program, each against fakes made the same
// way and on a data directory of its own: what every step answered, what each side's fakes were asked and told, and
// the files and tables each wrote, the same.
import assert from "node:assert/strict";
import { type ChildProcess, spawn } from "node:child_process";
import { createHash, generateKeyPairSync, sign as nodeSign } from "node:crypto";
import { EventEmitter } from "node:events";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { createServer, type Socket } from "node:net";
import { DatabaseSync } from "node:sqlite";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { after, mock, test } from "node:test";
import { Effect, Layer, Scope } from "effect";
import zhStation from "../../client/i18n/catalog/zh/station.json" with { type: "json" };
import enStation from "../../client/i18n/catalog/en/station.json" with { type: "json" };
import { type Kind, deviceRefusal, latest, signedBytes, timeoutRefusal, wellFormed } from "../../client/core-ts/src/rig-form.ts";
import { grantChatTitle } from "../src/adb/title.ts";
import type { Request } from "../src/api/request.ts";
import { type Entry, entryHash, fold, signedBytes as entryBytes } from "../src/cloud/lock.ts";
import { Cloud, writeState } from "../src/cloud/state.ts";
import { reachDevice } from "../src/devices/connect.ts";
import { ASK_MS, Elevation, applyScript, askScript, restartScript } from "../src/elevation/elevation.ts";
import { elevationRoutes } from "../src/elevation/module.ts";
import { Refused as PeerRefused } from "../src/mesh/bus.ts";
import { diskEvery, diskSoft, diskTier } from "../src/ops/disk.ts";
import { portsToTry } from "../src/ops/files.ts";
import { Fibers, wall } from "../src/ops/fibers.ts";
import { mbHarnessBinary } from "./mb-harness.ts";
import { RigGrants, signatureHolds } from "../src/rig/grants.ts";
import { Rig } from "../src/rig/module.ts";
import { addRefusal } from "../src/rigs/adds.ts";
import { RigsLive } from "../src/rigs/module.ts";
import { lasting, said } from "../src/rigs/requests.ts";
import { RIG_USE } from "../src/rigs/tool.ts";
import { ControlPlane, DeviceSources, Events, Parts, Store } from "../src/services.ts";
import { Agents } from "../src/sessions/agents.ts";
import { cardPlace, postCard } from "../src/sessions/card-place.ts";
import { STILLFAIL_SURFACE } from "../src/store/store.ts";
import { settle, testClock } from "./hub-fakes.ts";

const binary = mbHarnessBinary();
const skip = binary === null ? "the tests' MoonBit program (stillfail-reader-harness) is not built here" : false;

type Json = any;
const dirs: string[] = [];
const fresh = (prefix: string) => {
  const d = mkdtempSync(join(tmpdir(), prefix));
  dirs.push(d);
  return d;
};

let NOW = 1_800_000_000_000;
mock.method(wall, "now", () => NOW);
// (a request's id: `r_<now>` and six random letters, here always "i")
mock.method(Math, "random", () => 0.5);
const RANDOM = (0.5).toString(36).slice(2, 8);

const U = { $u: 1 };
const out = (v: unknown) => (v === undefined ? U : v);
const back = (v: Json) => (v !== null && typeof v === "object" && !Array.isArray(v) && Object.keys(v).length === 1 && v.$u === 1 ? undefined : v);
const errorOf = (e: unknown) => ({ error: (e as Error).message });
/// What an op answered, nothing (undefined) said as null on both sides.
const norm = (v: Json) => (v === undefined || (v !== null && typeof v === "object" && !Array.isArray(v) && Object.keys(v).length === 1 && v.$u === 1) ? null : v);

/// The program, asked a line at a time; what it asks of the station answered by `world`.
class Program {
  #child: ChildProcess;
  #next = 0;
  #cid = 0;
  #waiting = new Map<number, (v: Json) => void>();
  #cbs = new Map<number, (v: Json) => void>();
  world: (name: string, args: Json[]) => Promise<unknown> = async (name) => {
    throw new Error(`no world for ${name}`);
  };
  constructor() {
    this.#child = spawn(binary!, ["--builder", "harness-rigs-mode", "--shell-dir", fresh("rigs-mode-shell-")], { stdio: ["pipe", "pipe", "inherit"] });
    createInterface({ input: this.#child.stdout! }).on("line", (line) => {
      const said = JSON.parse(line);
      if (said.call !== undefined) return void this.#answer(said);
      if (said.cbre !== undefined) {
        this.#cbs.get(said.cbre)?.(said);
        this.#cbs.delete(said.cbre);
        return;
      }
      this.#waiting.get(said.re)?.(said);
      this.#waiting.delete(said.re);
    });
  }
  #say(v: Json) {
    this.#child.stdin!.write(`${JSON.stringify(v)}\n`);
  }
  /// A callback the program gave, as the function the station's fakes call.
  #fns(v: Json): Json {
    if (Array.isArray(v)) return v.map((x) => this.#fns(x));
    if (v !== null && typeof v === "object") {
      if (typeof v.$cb === "number" && Object.keys(v).length === 1) {
        const id = v.$cb;
        return (...args: Json[]) =>
          new Promise((resolve, reject) => {
            const cid = ++this.#cid;
            this.#cbs.set(cid, (a) => (a.threw !== undefined ? reject(new Error(a.threw)) : resolve(back(a.result))));
            this.#say({ cb: id, cid, args: args.map(out) });
          });
      }
      if (v.$u === 1 && Object.keys(v).length === 1) return undefined;
    }
    return v;
  }
  async #answer(c: Json) {
    try {
      const result = await this.world(c.name, (c.args as Json[]).map((a) => this.#fns(a)));
      this.#say({ re: c.call, result: out(result) });
    } catch (e) {
      this.#say({ re: c.call, threw: (e as Error).message, kind: (e as Error).constructor.name });
    }
  }
  /// An op's answer, or `{error}` where it raised.
  ask(op: string, a: Json = {}): Promise<Json> {
    const id = ++this.#next;
    return new Promise((resolve) => {
      this.#waiting.set(id, (said) => resolve(said.error !== undefined ? { error: said.error, kind: said.kind, ...(said.status !== undefined ? { status: said.status } : {}), ...(said.key !== undefined ? { key: said.key } : {}) } : { ok: back(said.ok) }));
      this.#say({ ...a, id, op });
    });
  }
  async must(op: string, a: Json = {}): Promise<Json> {
    const got = await this.ask(op, a);
    if ("error" in got) throw new Error(`${op}: ${got.error}`);
    return got.ok;
  }
  close(): Promise<void> {
    return ended(this.#child);
  }
}

/// A child let go: its stdin ended, and waited for until it is gone (killed 2 s after where it is not).
function ended(child: ChildProcess): Promise<void> {
  if (child.exitCode !== null || child.signalCode !== null) return Promise.resolve();
  const gone = new Promise<void>((r) => child.once("exit", () => r()));
  child.stdin?.end();
  setTimeout(() => child.kill("SIGKILL"), 2000).unref();
  return gone;
}

const programs: Program[] = [];
// (each program waited for till it is gone, the directories after: one still running at the file's end is a leftover)
after(async () => {
  await Promise.all(programs.map((p) => p.close()));
  for (const d of dirs) rmSync(d, { recursive: true, force: true });
});
const program = () => {
  const p = new Program();
  programs.push(p);
  return p;
};

// ── keys and what they sign ─────────────────────────────────────────────────────────────────────────────────────

const sha256 = (bytes: Uint8Array) => createHash("sha256").update(bytes).digest();
function ed() {
  const { privateKey, publicKey } = generateKeyPairSync("ed25519");
  const hex = (publicKey.export({ format: "der", type: "spki" }) as Buffer).subarray(-32).toString("hex");
  return { hex, id: `ed25519:${hex}`, sign: (bytes: Uint8Array) => nodeSign(null, bytes, privateKey).toString("hex") };
}
type Key = ReturnType<typeof ed>;
const sealed = (e: Omit<Entry, "sig">, key: Key): Entry => ({ ...e, sig: { key: key.id, alg: "Ed25519", sig: key.sign(entryBytes(entryHash(e as Entry))) } }) as Entry;

/// A person's own lock: its chain as made so far, and a statement signed by one of its keys.
function person(sub: string) {
  const first = ed();
  const chain: Entry[] = [];
  const add = (kind: string, body: unknown, by: Key) => {
    const last = chain[chain.length - 1];
    chain.push(sealed({ v: 1, ws: `person:${sub}`, seq: chain.length, prev: last ? entryHash(last) : null, at: 1000, kind, body } as Omit<Entry, "sig">, by));
  };
  add("genesis", { sub, device: { key: first.id, id: ed().hex, label: "first" } }, first);
  const says = <B>(kind: Kind, body: B, by: Key = first) => ({ body, sig: { key: by.id, sig: by.sign(signedBytes(kind, body, sha256)) } });
  return { sub, first, chain, add, says, genesis: () => entryHash(chain[0]!) };
}

const WS = "01WORKSPACE";
const RIG = "aa".repeat(32);
const STATION = "bb".repeat(32);
const OTHER = "cc".repeat(32);
const START = 1_800_000_000_000;
const secs = (ms: number) => Math.floor(ms / 1000);

// ── the pure parts ──────────────────────────────────────────────────────────────────────────────────────────────

test("the rig's forms, the words an agent reads and the scripts run elevated are the TypeScript's", { skip }, async () => {
  const p = program();
  const owner = person("pat");
  const t0 = secs(START);
  const grant = (more: Json = {}) => owner.says("grant", { v: 1, sub: "pat", ws: WS, rig: RIG, station: STATION, session: "s1", chat: "CHAT/s1", request: "r1", title: "t", by: "b", timeout: { kind: "idle", seconds: 3600 }, at: t0, exp: t0 + 3600, ...more });
  const signedCases: [Kind, Json][] = [
    ["grant", grant()], ["grant", grant({ device: "0123456789abcdef" })], ["grant", grant({ device: "nothex" })], ["grant", grant({ exp: t0 })],
    ["grant", grant({ timeout: { kind: "idle", seconds: 61 } })], ["grant", grant({ station: "BB".repeat(32) })], ["grant", grant({ session: "" })],
    ["grant", grant({ title: "x".repeat(513) })], ["grant", grant({ exp: t0 + 31 * 86400 })], ["grant", { body: grant().body, sig: { key: 5, sig: "00" } }],
    ["grant", null], ["grant", [1]], ["grant", { body: [], sig: {} }], ["revoke", owner.says("revoke", { v: 1, sub: "pat", ws: WS, rig: RIG, request: "r1", at: t0 })],
    ["revoke", owner.says("revoke", { v: 1, sub: "pat", ws: WS, rig: RIG, request: "", at: t0 })], ["settings", owner.says("settings", { v: 1, sub: "pat", ws: WS, rig: RIG, seq: 3, open: true, at: t0 })],
    ["settings", owner.says("settings", { v: 1, sub: "pat", ws: WS, rig: RIG, seq: 3, open: "yes", at: t0 })], ["settings", owner.says("settings", { v: 1, sub: "pat", ws: "x".repeat(65), rig: RIG, seq: 3, open: true, at: t0 })],
    ["add", owner.says("add", { v: 1, sub: "pat", ws: WS, rig: RIG, at: t0 })], ["full", owner.says("full", { v: 2, sub: "pat", ws: WS, rig: RIG, at: t0 })],
    ["device", owner.says("device", { v: 1, sub: "pat", ws: WS, rig: RIG, device: { id: "0123456789abcdef", name: "cam", kind: "tcp", target: "10.0.0.2:554" }, removed: false, at: t0 })],
    ["device", owner.says("device", { v: 1, sub: "pat", ws: WS, rig: RIG, device: { id: "0123456789abcdef", name: "cam", kind: "tcp", target: "10.0.0.2:554" }, removed: "no", at: t0 })],
  ];
  for (const [kind, signed] of signedCases) {
    for (const k of ["grant", "revoke", "settings", "add", "full", "device"] as Kind[]) {
      assert.equal(await p.must("wellFormed", { kind: k, signed }), wellFormed(k, signed), `${k} of ${JSON.stringify(signed).slice(0, 80)}`);
    }
    assert.equal(await p.must("signatureHolds", { kind, signed }), signed !== null && typeof signed === "object" && !Array.isArray(signed) ? signatureHolds(kind, signed) : false);
    if (signed?.body && wellFormed(kind, signed)) assert.equal(await p.must("signedBytes", { kind, body: signed.body }), Buffer.from(signedBytes(kind, signed.body, sha256)).toString("hex"));
  }
  // a signature of one kind is none of another
  assert.equal(await p.must("signatureHolds", { kind: "revoke", signed: grant() }), false);
  for (const t of [{ kind: "idle", seconds: 60 }, { kind: "fixed", seconds: 2592000 }, { kind: "fixed", seconds: 2592060 }, { kind: "idle", seconds: 90 }, { kind: "always", seconds: 600 }, null, [], { kind: "idle" }, { kind: "idle", seconds: 600.5 }]) {
    assert.deepEqual(await p.must("timeoutRefusal", { t }), timeoutRefusal(t), JSON.stringify(t));
    assert.equal(await p.must("lasting", { t }), t !== null && typeof t === "object" && typeof (t as Json).seconds === "number" ? lasting(t as Json) : await p.must("lasting", { t }));
    if (t !== null && typeof t === "object") assert.equal(await p.must("latest", { at: 1000, timeout: t }), latest(1000, t as Json));
  }
  for (const s of [60, 600, 3600, 5400, 86400, 172800, 90000]) for (const kind of ["idle", "fixed"]) assert.equal(await p.must("lasting", { t: { kind, seconds: s } }), lasting({ kind: kind as "idle", seconds: s }));
  const devices = [
    { id: "0123456789abcdef", name: "cam", kind: "tcp", target: "10.0.0.2:554" }, { id: "0123456789abcdef", name: " ", kind: "tcp", target: "10.0.0.2:554" },
    { id: "0123456789ABCDEF", name: "cam", kind: "tcp", target: "x:1" }, { id: "0123456789abcdef", name: "cam", kind: "tcp", target: "[fe80::1]:80" },
    { id: "0123456789abcdef", name: "cam", kind: "tcp", target: "host:65536" }, { id: "0123456789abcdef", name: "cam", kind: "tcp", target: "host:0" },
    { id: "0123456789abcdef", name: "cam", kind: "tcp", target: "a b:1" }, { id: "0123456789abcdef", name: "cam", kind: "tcp", target: "host" },
    { id: "0123456789abcdef", name: "cam", kind: "serial", target: "/dev/ttyUSB0", baud: 115200 }, { id: "0123456789abcdef", name: "cam", kind: "serial", target: "COM3" },
    { id: "0123456789abcdef", name: "cam", kind: "serial", target: "ttyUSB0" }, { id: "0123456789abcdef", name: "cam", kind: "serial", target: "/dev/x", baud: 10 },
    { id: "0123456789abcdef", name: "cam", kind: "serial", target: "/dev/x", baud: null }, { id: "0123456789abcdef", name: "x".repeat(81), kind: "adb", target: "emulator-5554" },
    { id: "0123456789abcdef", name: "phone", kind: "adb", target: "emulator-5554" }, { id: "0123456789abcdef", name: "phone", kind: "usb", target: "x" },
    { id: "0123456789abcdef", name: "phone", kind: "adb", target: "a\u00a0b" }, null, "x", [],
  ];
  for (const d of devices) assert.deepEqual(await p.must("deviceRefusal", { d }), deviceRefusal(d), JSON.stringify(d));
  // what an agent is told of its request, each way it can stand
  const base = { id: "r_1", ws: WS, session: "s", chat: "C/1", rig: RIG, rigName: "box", owner: "pat", ownerEmail: "", reason: "x", timeout: { kind: "idle", seconds: 3600 }, at: 1, title: "", by: "" };
  for (const status of ["pending", "granted", "denied", "ended"]) {
    for (const more of [{}, { delivered: true }, { why: "因为" }, { ownerEmail: "p@x" }, { device: "0123456789abcdef" }, { device: "0123456789abcdef", deviceName: "cam", delivered: true }, { signed: { body: { timeout: { kind: "fixed", seconds: 600 } } }, delivered: true }]) {
      const r = { ...base, status, ...more };
      assert.equal(await p.must("said", { r }), said(r as Json), JSON.stringify(r));
    }
  }
  // the disk as it fills, the door's ports
  for (const [free, total] of [[1e9, 1e12], [25 * 1024 ** 3, 1e12], [25 * 1024 ** 3, 2e11], [200e9, 1e12], [50e9, 1e11]]) {
    assert.equal(await p.must("diskTier", { free, total }), diskTier(free!, total!));
    assert.equal(await p.must("diskSoft", { total }), diskSoft(total!));
  }
  for (const tier of ["ok", "soft", "low"] as const) assert.equal(await p.must("diskEvery", { tier }), diskEvery(tier));
  for (const [named, remembered, own] of [[undefined, undefined, true], [8000, 4751, true], [undefined, 4751, false], [undefined, 4750, true], [undefined, 0, true]] as const) {
    assert.deepEqual(await p.must("portsToTry", { ...(named !== undefined ? { named } : {}), ...(remembered !== undefined ? { remembered } : {}), usual: 4750, own }), portsToTry(named, remembered, 4750, own));
  }
  // the scripts run elevated, every way they are made
  for (const elevate of [true, false]) assert.equal(await p.must("askScript", { apply: "C:\\d's\\run\\elevation-apply.ps1", elevate }), askScript("C:\\d's\\run\\elevation-apply.ps1", elevate));
  for (const on of [true, false]) {
    for (const restart of [true, false]) {
      const o = { run: "/data/run", data: "/data", task: "it's a task", on, deadline: 1_800_000_120_000, restart, runner: "/data/run/w.exe" };
      assert.equal(await p.must("applyScript", o), applyScript(o));
    }
    const o = { run: "/data/run", data: "/data", app: "/data/app", task: "still.fail station", on };
    assert.equal(await p.must("restartScript", o), restartScript(o));
  }
  for (const parts of [["/d", "run"], ["/d/", "run", "x.json"], ["/d", "../e", "./f"], ["a", "", "b"], ["/"]]) assert.equal(await p.must("pathJoin", { parts }), join(...parts));
  for (const ms of [0, START, 1_700_000_123_456, 253402300799999]) assert.equal(await p.must("iso", { ms }), new Date(ms).toISOString());
  assert.equal(await p.must("requestId", { now: START, random: RANDOM }), `r_${START.toString(36)}${RANDOM}`);
  // station_use as declared
  assert.deepEqual(await p.must("rigUse"), RIG_USE);
});

test("security mode: what takes a rig into a workspace is what the TypeScript takes", { skip }, async () => {
  const p = program();
  const alice = { sub: "alice", signer: ed(), base: ed() };
  const pat = { sub: "pat", signer: ed(), base: ed() };
  const g = sealed({ v: 1, ws: WS, seq: 0, prev: null, at: 1000, kind: "genesis", body: {
    owner: "alice", origins: ["https://app.still.fail"], rp_id: "app.still.fail", cloud_keys: { keys: [] },
    members: [{ sub: "alice", email: "a@x", role: "owner" }, { sub: "pat", email: "p@x", role: "member" }, { sub: "vic", email: "v@x", role: "viewer" }],
    devices: [alice, pat].map((d) => ({ id: d.base.hex, sub: d.sub, kind: "app", label: d.sub, sign_key: d.signer.id })),
    passkeys: [], stations: [], gateways: [],
  } } as Json, alice.signer);
  const personal = ed();
  const chain = sealed({ v: 1, ws: "person:pat", seq: 0, prev: null, at: 1000, kind: "genesis", body: { sub: "pat", device: { key: personal.id, id: ed().hex, label: "first" } } } as Json, personal);
  const bound = sealed({ v: 1, ws: WS, seq: 1, prev: entryHash(g), at: 2000, kind: "person", body: { sub: "pat", person: entryHash(chain) } } as Json, pat.signer);
  const removed = sealed({ v: 1, ws: WS, seq: 2, prev: entryHash(bound), at: 2500, kind: "member.remove", body: { sub: "pat" } } as Json, alice.signer);
  const rig = { id: RIG, name: "build-box", owner: "pat", owner_email: "p@x", owner_name: "Pat" };
  const add = (by: Key, more: Json = {}) => ({ body: { v: 1, sub: "pat", ws: WS, rig: RIG, at: 2000, ...more }, sig: { key: by.id, sig: by.sign(signedBytes("add", { v: 1, sub: "pat", ws: WS, rig: RIG, at: 2000, ...more }, sha256)) } });
  const keys = { [entryHash(chain)]: [personal.id] };
  for (const entries of [[g], [g, bound], [g, bound, removed]]) {
    const lock = fold(entries, null);
    for (const [signed, r] of [
      [add(pat.signer), rig], [add(alice.signer), rig], [add(ed()), rig], [add(pat.signer, { rig: "cc".repeat(32) }), rig], [add(personal), rig],
      [add(alice.signer, { sub: "alice" }), rig], [{ ...add(pat.signer), sig: { key: pat.signer.id, sig: "00".repeat(64) } }, rig], [add(pat.signer), { ...rig, owner: "vic" }],
      [null, rig], [{ body: {}, sig: {} }, rig],
    ] as [Json, Json][]) {
      for (const ws of [WS, "other"]) {
        const want = addRefusal(signed, ws, r, lock, (gen) => new Set(keys[gen] ?? []), 3000);
        assert.deepEqual(await p.must("addRefusal", { signed, ws, rig: r, entries, personKeys: keys, now: 3000 }), want, `${entries.length} ${ws} ${JSON.stringify(signed?.body ?? null)}`);
      }
    }
  }
});

// ── a rig's grants ──────────────────────────────────────────────────────────────────────────────────────────────

type Side = {
  call(name: string, ...args: Json[]): Promise<Json>;
  pass(ms: number): Promise<void>;
  busy(keys: string[]): Promise<void>;
  running(pairs: string[][]): Promise<void>;
  events(): Promise<Json[]>;
  file(): Promise<string | null>;
  reopen(): Promise<void>;
};

/// The TypeScript's RigGrants on a test's clock, its fakes saying what they were told as events.
async function tsGrants(path: string, person: string): Promise<Side> {
  const time = testClock();
  await time.adjust(START);
  const fibers = new Fibers("rig-test", time.clock);
  const busy = new Set<string>();
  let running: string[][] = [];
  const events: Json[] = [];
  const make = () =>
    new RigGrants({
      path,
      self: () => ({ id: RIG, workspace: WS, owner: "pat", person }),
      busy: (station, session) => busy.has(`${station}/${session}`),
      stop: (station, session) => void events.push(["stop", station, session]),
      running: () => running.map(([station, session]) => ({ station: station!, session: session! })),
      ended: (e) => void events.push(["ended", e]),
      changed: () => void events.push(["changed"]),
      cut: (device, station, session) => void events.push(["cut", device, station, session]),
      fibers,
    });
  let g = make();
  return {
    async call(name, ...args) {
      try {
        return { ok: norm((g as Json)[name](...args)) };
      } catch (e) {
        return errorOf(e);
      }
    },
    async pass(ms) {
      await time.adjust(ms);
      await settle();
    },
    async busy(keys) {
      busy.clear();
      for (const k of keys) busy.add(k);
    },
    async running(pairs) {
      running = pairs;
    },
    async events() {
      await settle();
      return events.splice(0);
    },
    async file() {
      await g.written();
      return existsSync(path) ? readFileSync(path, "utf8") : null;
    },
    async reopen() {
      await g.written();
      g.close();
      g = make();
    },
  };
}

async function mbGrants(path: string, person: string, at: number): Promise<Side> {
  const p = program();
  await p.must("now", { ms: at });
  await p.must("mirror", { self: { id: RIG, workspace: WS, owner: "pat", person } });
  await p.must("grants.new", { path });
  const call = async (name: string, ...args: Json[]) => {
    const got = await p.ask("grants", { name: name === "settings" ? "settings" : name, args: args.map(out) });
    return "error" in got ? { error: got.error } : { ok: norm(got.ok) };
  };
  return {
    call,
    pass: (ms) => p.must("pass", { ms }),
    busy: (keys) => p.must("mirror", { busy: keys }),
    running: (pairs) => p.must("mirror", { running: pairs }),
    events: async () => {
      await p.must("settle");
      return p.must("events");
    },
    file: async () => (existsSync(path) ? readFileSync(path, "utf8") : null),
    reopen: async () => {
      await p.must("grants", { name: "close", args: [] });
      await p.must("grants.new", { path });
    },
  };
}

/// What a script made of a side: each step's answer, the events after it, the file at the end.
async function traced(side: Side, script: (s: Side, t: (label: string, v: Json) => void) => Promise<void>): Promise<Json[]> {
  const trace: Json[] = [];
  await script(side, (label, v) => void trace.push([label, v]));
  trace.push(["events", await side.events()]);
  trace.push(["file", await side.file()]);
  return trace;
}

function assertSame(a: Json[], b: Json[]) {
  assert.equal(b.length, a.length, "as many steps");
  for (let i = 0; i < a.length; i++) assert.deepEqual(b[i], a[i], `step ${i}: ${JSON.stringify(a[i]).slice(0, 200)}`);
}

test("a rig's grants: what its person signed checked, timed out, idle, taken back, 免批准, devices, kept and read again", { skip }, async () => {
  const owner = person("pat");
  const second = ed();
  const t0 = secs(START);
  const grant = (request: string, session: string, timeout: Json, at: number, more: Json = {}, by?: Key) =>
    owner.says("grant", { v: 1, sub: "pat", ws: WS, rig: RIG, station: STATION, session, chat: `CHAT/${session}`, request, title: `chat ${session}`, by: "lee@example.com", timeout, at, exp: latest(at, timeout), ...more }, by);
  const settings = (seq: number, open: boolean, at: number, device?: string) => owner.says("settings", { v: 1, sub: "pat", ws: WS, rig: RIG, seq, open, at, ...(device ? { device } : {}) });
  const cam = { id: "0123456789abcdef", name: "cam", kind: "tcp", target: "192.168.1.20:554" };
  const attach = (removed: boolean, at: number) => owner.says("device", { v: 1, sub: "pat", ws: WS, rig: RIG, device: cam, removed, at });
  const before = [...owner.chain];
  owner.add("device", { key: second.id, id: ed().hex, label: "second" }, owner.first);
  const withSecond = [...owner.chain];
  owner.add("device.remove", { key: second.id }, owner.first);
  const stranger = person("pat");
  const script = async (s: Side, t: (label: string, v: Json) => void) => {
    // (the side's clock, which the grants are signed by)
    let clock = START;
    const pass = async (ms: number) => {
      clock += ms;
      await s.pass(ms);
    };
    const step = async (label: string, name: string, ...args: Json[]) => {
      t(label, await s.call(name, ...args));
      t(`${label} events`, await s.events());
    };
    await step("refused", "refusal", WS, STATION, "s1");
    await step("other ws", "refusal", "other", STATION, "s1");
    await step("no lock", "grant", STATION, grant("r1", "s1", { kind: "idle", seconds: 3600 }, t0));
    await step("other station", "grant", OTHER, grant("r1", "s1", { kind: "idle", seconds: 3600 }, t0), before);
    await step("other rig", "grant", STATION, grant("r1", "s1", { kind: "idle", seconds: 3600 }, t0, { rig: "dd".repeat(32) }), before);
    await step("stranger's lock", "grant", STATION, grant("r1", "s1", { kind: "idle", seconds: 3600 }, t0), stranger.chain);
    await step("malformed lock", "takeChain", [{ v: 1 }]);
    await step("granted", "grant", STATION, grant("r1", "s1", { kind: "idle", seconds: 3600 }, t0), before);
    await step("second key", "grant", STATION, grant("r2", "s2", { kind: "fixed", seconds: 600 }, t0, {}, second), withSecond);
    await step("second off", "takeChain", owner.chain);
    await step("older chain", "takeChain", before);
    await step("second key off", "grant", STATION, grant("r3", "s3", { kind: "fixed", seconds: 600 }, t0, {}, second), before);
    await step("at odds", "takeChain", stranger.chain);
    await step("used", "refusal", WS, STATION, "s1");
    await step("station", "stationRefusal", WS, STATION);
    await step("view", "view");
    await pass(300_000);
    await step("still", "refusal", WS, STATION, "s1");
    await pass(301_000);
    t("after the fixed one", await s.events());
    await s.busy([`${STATION}/s1`]);
    await pass(3_600_000);
    t("busy holds", await s.events());
    await s.busy([]);
    await pass(3_601_000);
    t("idle", await s.events());
    // 免批准
    await step("open", "settings", settings(1, true, t0), owner.chain);
    await step("anyone", "refusal", WS, OTHER, "anyone");
    await step("grant while open", "grant", STATION, grant("r4", "s4", { kind: "idle", seconds: 3600 }, secs(clock)));
    await s.running([[STATION, "s4"], [OTHER, "free"]]);
    await step("closed", "settings", settings(2, false, t0));
    await step("older settings", "settings", settings(1, true, t0));
    await step("same settings", "settings", settings(2, false, t0));
    // a device
    await step("no device", "deviceRefusal", WS, STATION, "s1", cam.id);
    await step("stranger's device", "device", stranger.says("device", { v: 1, sub: "pat", ws: WS, rig: RIG, device: cam, removed: false, at: t0 }));
    await step("attached", "device", attach(false, t0));
    await step("devices", "devices");
    await step("no grant of it", "deviceRefusal", WS, STATION, "s5", cam.id);
    await step("its grant", "grant", STATION, grant("d1", "s5", { kind: "fixed", seconds: 600 }, secs(clock), { device: cam.id }));
    await step("reached", "deviceRefusal", WS, STATION, "s5", cam.id);
    await step("not the rig", "refusal", WS, STATION, "s5");
    await step("no such device", "grant", STATION, grant("d9", "s6", { kind: "fixed", seconds: 600 }, secs(clock), { device: "fedcba9876543210" }));
    await step("device open", "settings", settings(1, true, t0, cam.id));
    await step("device closed", "settings", settings(2, false, t0, cam.id));
    await step("older device settings", "settings", settings(1, true, t0, cam.id));
    await step("view with device", "view");
    await pass(601_000);
    await step("looked at", "view");
    await step("another of it", "grant", STATION, grant("d2", "s7", { kind: "fixed", seconds: 600 }, secs(clock), { device: cam.id }));
    await step("taken off", "device", attach(true, t0 + 1));
    await step("older device", "device", attach(false, t0));
    await step("again", "device", attach(false, t0 + 2));
    // given back and taken back
    await step("released by another", "release", OTHER, "r4");
    await step("released", "release", STATION, "r4");
    const revoke = owner.says("revoke", { v: 1, sub: "pat", ws: WS, rig: RIG, request: "r9", at: t0 });
    await step("revoked before", "revoke", revoke);
    await step("revoked comes", "grant", STATION, grant("r9", "s9", { kind: "idle", seconds: 3600 }, secs(clock)));
    await step("proof", "proof");
    await step("added", "added", owner.says("add", { v: 1, sub: "pat", ws: WS, rig: RIG, at: t0 }));
    await step("added for another", "added", owner.says("add", { v: 1, sub: "lee", ws: WS, rig: RIG, at: t0 }));
    await step("proof kept", "proof");
    const now = secs(clock);
    await step("full", "full", owner.says("full", { v: 1, sub: "pat", ws: WS, rig: RIG, at: now }));
    await step("full late", "full", owner.says("full", { v: 1, sub: "pat", ws: WS, rig: RIG, at: now - 7200 }));
    await step("full early", "full", owner.says("full", { v: 1, sub: "pat", ws: WS, rig: RIG, at: now + 301 }));
    await step("kept grant", "grant", STATION, grant("k1", "s10", { kind: "idle", seconds: 3600 }, now));
    t("file before", await s.file());
    await s.reopen();
    await step("read again", "view");
    await step("kept", "refusal", WS, STATION, "s10");
    await step("open read again", "open");
  };
  const tsDir = fresh("rig-grants-ts-");
  const mbDir = fresh("rig-grants-mb-");
  const a = await traced(await tsGrants(join(tsDir, "grants.json"), owner.genesis()), script);
  const b = await traced(await mbGrants(join(mbDir, "grants.json"), owner.genesis(), START), script);
  assertSame(a, b);
  // A file another wrote, unreadable or of another shape, read as the TypeScript reads it.
  for (const text of ["not json", "null", "[1,2]", JSON.stringify({ chain: "x", grants: [{ signed: 1 }], revoked: { r: 1.5, s: 7 }, devices: { x: {} }, deviceSettings: "ab" })]) {
    const tp = join(fresh("rig-grants-ts-"), "grants.json");
    const mp = join(fresh("rig-grants-mb-"), "grants.json");
    writeFileSync(tp, text);
    writeFileSync(mp, text);
    const ts = await tsGrants(tp, owner.genesis());
    const mb = await mbGrants(mp, owner.genesis(), START);
    assert.deepEqual(await mb.call("view"), await ts.call("view"), text);
    await ts.call("grant", STATION, grant("n1", "s1", { kind: "idle", seconds: 3600 }, t0), owner.chain);
    await mb.call("grant", STATION, grant("n1", "s1", { kind: "idle", seconds: 3600 }, t0), owner.chain);
    assert.equal(await mb.file(), await ts.file(), text);
  }
});

// ── a rig on the station transport ──────────────────────────────────────────────────────────────────────────────

/// A machine's cloud.json, read as the station reads it.
function cloudData(state: Json): string {
  const data = fresh("rigs-mode-cloud-");
  writeState(data, { origin: "https://app.still.fail", relay_url: "", relay_urls: [], grant_keys: { keys: [] }, revocations: [], workspace_name: "Team", name: "", ...state } as Json);
  return data;
}

/// A station of the workspace as a rig reaches it: told or not, refusing or away.
function stationFakes() {
  const told: Json[] = [];
  const how = new Map<string, "ok" | "away" | "refuses">();
  return {
    told, how,
    ask: async (station: string, request: Json) => {
      told.push([station, request]);
      const h = how.get(station) ?? "ok";
      if (h === "away") throw new Error("peer unavailable");
      if (h === "refuses") throw new PeerRefused("not a station of this workspace");
      return { ok: true };
    },
  };
}

type RigSide = {
  op(name: string, a?: Json): Promise<Json>;
  pass(ms: number): Promise<void>;
  how(station: string, h: "ok" | "away" | "refuses"): void;
  told(): Promise<Json[]>;
  events(): Promise<Json[]>;
  files(): Promise<Json>;
  sockets(): number;
};

test("a rig: what it answers and refuses, what it keeps of what it was told to run, what it tells the stations", { skip }, async () => {
  const owner = person("pat");
  const t0 = secs(START);
  const state = { station: RIG, workspace: WS, peers: [{ id: STATION }, { id: OTHER }, { id: RIG }], rig: { owner: "pat", owner_email: "pat@example.com", owner_name: "Pat", person: owner.genesis() } };
  const server = createServer((socket) => void socket.on("error", () => {}));
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  const port = (server.address() as Json).port;
  const cam = { id: "0123456789abcdef", name: "cam", kind: "tcp", target: `127.0.0.1:${port}` };
  const grant = (request: string, session: string, timeout: Json, at: number, more: Json = {}) =>
    owner.says("grant", { v: 1, sub: "pat", ws: WS, rig: RIG, station: STATION, session, chat: `CHAT/${session}`, request, title: "a chat", by: "lee@example.com", timeout, at, exp: latest(at, timeout), ...more });

  async function tsRig(data: string): Promise<RigSide> {
    const time = testClock();
    await time.adjust(START);
    const fibers = new Fibers("rig-test", time.clock);
    const cloud = new Cloud(data, false);
    const fakes = stationFakes();
    const events: Json[] = [];
    const busy = new Set<string>();
    let guard: Json = null, heard: Json = null, attached: Json = null;
    const bus: Json = {
      guarded: (f: Json) => void (guard = f),
      on: (_prefix: string, f: Json) => void (heard = f),
      whenAttached: (f: Json) => void (attached = f),
      ask: fakes.ask,
    };
    const rig = new Rig({ data, cloud, bus, fibers, busy: (w, st, se) => busy.has(`${w}/${st}/${se}`), stop: (w, st, se) => void events.push(["stop", w, st, se]), running: () => [] });
    const sockets: Socket[] = [];
    return {
      async op(name, a: Json = {}) {
        try {
          switch (name) {
            case "attached": return { ok: norm(attached()) };
            case "guard": return { ok: norm(guard(a.workspace, a.peer, a.request)) };
            case "heard": return { ok: norm(await heard(a.peer, a.request, a.workspace)) };
            case "described": return { ok: rig.described() };
            case "self": return { ok: rig.self() };
            case "stationRefusal": return { ok: rig.stationRefusal(a.peer, a.workspace) };
            case "device": {
              const s = await rig.device(a.peer, a.workspace, a.session, a.device, a.probe);
              if (s !== null) {
                sockets.push(s as Socket);
                (s as Socket).on("close", () => void events.push(["closed"]));
              }
              return { ok: s === null ? null : true };
            }
            case "busy": busy.clear(); for (const k of a.keys) busy.add(k); return { ok: null };
            case "update": cloud.update((st: Json) => Object.assign(st, a.set)); return { ok: null };
            case "log": return { ok: await rig.commands.last(a.limit) };
          }
          throw new Error(`no op ${name}`);
        } catch (e) {
          return { error: (e as Error).message, ...((e as Json).status !== undefined ? { status: (e as Json).status } : {}) };
        }
      },
      pass: async (ms) => {
        await time.adjust(ms);
        await settle();
      },
      how: (station, h) => void fakes.how.set(station, h),
      told: async () => {
        await settle();
        return fakes.told.splice(0);
      },
      events: async () => {
        await settle();
        return events.splice(0);
      },
      files: async () => {
        await rig.commands.written();
        await rig.grants.written();
        const read = (f: string) => (existsSync(join(data, "rig", f)) ? readFileSync(join(data, "rig", f), "utf8") : null);
        return { grants: read("grants.json"), commands: read("commands.log"), cloud: JSON.parse(readFileSync(join(data, "mesh", "cloud.json"), "utf8")).full_pending ?? null };
      },
      sockets: () => sockets.filter((s) => !s.destroyed).length,
    };
  }

  async function mbRig(data: string): Promise<RigSide> {
    const p = program();
    const fakes = stationFakes();
    const sockets = new Map<string, Socket>();
    p.world = async (name, args) => {
      if (name === "bus.ask") return fakes.ask(args[0], args[1]);
      if (name === "reach") {
        const s = await reachDevice(args[0]);
        const id = String(sockets.size + 1);
        sockets.set(id, s as Socket);
        (s as Socket).on("close", () => void p.ask("rig.socketClosed", { socket: id }));
        return id;
      }
      throw new Error(`no world ${name}`);
    };
    await p.must("now", { ms: START });
    await p.must("cloud.open", { data });
    await p.must("rig.new", { data });
    const events: Json[] = [];
    const take = async () => {
      await p.must("settle");
      for (const e of await p.must("events")) {
        if (e[0] === "destroy") {
          sockets.get(e[1])!.destroy();
        } else events.push(e);
      }
      await settle();
      await p.must("settle");
    };
    return {
      async op(name, a: Json = {}) {
        const map: Record<string, string> = { attached: "rig.attached", guard: "rig.guard", heard: "rig.heard", described: "rig.described", self: "rig.self", stationRefusal: "rig.stationRefusal", device: "rig.device", log: "rig.log" };
        if (name === "busy") return { ok: await p.must("mirror", { busy: a.keys }) };
        if (name === "update") return { ok: await p.must("cloud.update", { set: a.set }) };
        if (name === "device") {
          const got = await p.ask("rig.device", a);
          await take();
          if ("error" in got) return { error: got.error, status: got.status };
          if (got.ok === true) {
            const s = [...sockets.values()].at(-1)!;
            s.on("close", () => void events.push(["closed"]));
          }
          return { ok: got.ok };
        }
        const got = await p.ask(map[name]!, a);
        await take();
        return "error" in got ? { error: got.error } : { ok: norm(got.ok) };
      },
      pass: async (ms) => {
        await p.must("pass", { ms });
        await take();
      },
      how: (station, h) => void fakes.how.set(station, h),
      told: async () => {
        await take();
        return fakes.told.splice(0);
      },
      events: async () => {
        await take();
        return events.splice(0);
      },
      files: async () => {
        await p.must("rig.written");
        const read = (f: string) => (existsSync(join(data, "rig", f)) ? readFileSync(join(data, "rig", f), "utf8") : null);
        return { grants: read("grants.json"), commands: read("commands.log"), cloud: JSON.parse(readFileSync(join(data, "mesh", "cloud.json"), "utf8")).full_pending ?? null };
      },
      sockets: () => [...sockets.values()].filter((s) => !s.destroyed).length,
    };
  }

  const script = async (s: RigSide, t: (label: string, v: Json) => void) => {
    const step = async (label: string, name: string, a: Json = {}) => {
      t(label, await s.op(name, a));
      t(`${label} told`, await s.told());
      t(`${label} events`, await s.events());
    };
    await step("self", "self");
    await step("described", "described");
    s.how(OTHER, "away");
    await step("attached", "attached");
    await s.pass(1000);
    t("told again", await s.told());
    s.how(OTHER, "refuses");
    await s.pass(2000);
    t("refused, not again", await s.told());
    await s.pass(60_000);
    t("nothing more", await s.told());
    const prepare = { method: "task.prepare", session: "s1", key: "k", spec: { name: "build", command: "make -j8" } };
    await step("no grant", "guard", { workspace: WS, peer: STATION, request: prepare });
    await step("no session", "guard", { workspace: WS, peer: STATION, request: { method: "session.create" } });
    await step("ungated", "guard", { workspace: WS, peer: STATION, request: { method: "task.get", session: "s1" } });
    await step("rig's own", "guard", { workspace: WS, peer: STATION, request: { method: "rig.anything" } });
    await step("grant", "heard", { peer: STATION, workspace: WS, request: { method: "rig.grant", signed: grant("r1", "s1", { kind: "fixed", seconds: 3600 }, t0), chain: owner.chain } });
    await step("other workspace", "heard", { peer: STATION, workspace: "other", request: { method: "rig.describe" } });
    await step("unknown", "heard", { peer: STATION, workspace: WS, request: { method: "rig.nothing" } });
    await step("prepared", "guard", { workspace: WS, peer: STATION, request: prepare });
    await step("secret", "guard", { workspace: WS, peer: STATION, request: { method: "vault.run", session: "s1", id: 7, command: "x".repeat(2100) } });
    await step("capture", "guard", { workspace: WS, peer: STATION, request: { method: "vault.capture", session: "s1", command: "deploy" } });
    await step("other chat", "guard", { workspace: WS, peer: STATION, request: { ...prepare, session: "s2" } });
    await step("services", "stationRefusal", { peer: STATION, workspace: WS });
    await step("services of another", "stationRefusal", { peer: OTHER, workspace: WS });
    await step("log", "heard", { peer: STATION, workspace: WS, request: { method: "rig.log", limit: 10 } });
    await step("log limits", "heard", { peer: STATION, workspace: WS, request: { method: "rig.log", limit: 0 } });
    await step("describe", "heard", { peer: STATION, workspace: WS, request: { method: "rig.describe" } });
    // a device, reached by the chat that holds the rig's grant; the grant gone, its connection cut
    await step("attached device", "heard", { peer: STATION, workspace: WS, request: { method: "rig.device", signed: owner.says("device", { v: 1, sub: "pat", ws: WS, rig: RIG, device: cam, removed: false, at: t0 }) } });
    await step("probe", "device", { peer: STATION, workspace: WS, session: "s1", device: cam.id, probe: true });
    await step("no grant of it", "device", { peer: STATION, workspace: WS, session: "s9", device: cam.id, probe: false });
    await step("no such", "device", { peer: STATION, workspace: WS, session: "s1", device: "fedcba9876543210", probe: false });
    await step("reached", "device", { peer: STATION, workspace: WS, session: "s1", device: cam.id, probe: false });
    t("open", s.sockets());
    await step("released", "heard", { peer: STATION, workspace: WS, request: { method: "rig.release", request: "r1" } });
    t("cut", s.sockets());
    await step("released again", "heard", { peer: STATION, workspace: WS, request: { method: "rig.release" } });
    // an idle grant runs out, a busy one does not
    await step("idle grant", "heard", { peer: STATION, workspace: WS, request: { method: "rig.grant", signed: grant("r2", "s2", { kind: "idle", seconds: 600 }, t0 + 63) } });
    await step("busy", "busy", { keys: [`${WS}/${STATION}/s2`] });
    await s.pass(1_200_000);
    t("held", await s.told());
    await step("not busy", "busy", { keys: [] });
    await s.pass(601_000);
    t("ended told", await s.told());
    t("ended events", await s.events());
    // settings, an add, whole again
    await step("open", "heard", { peer: OTHER, workspace: WS, request: { method: "rig.settings", signed: owner.says("settings", { v: 1, sub: "pat", ws: WS, rig: RIG, seq: 1, open: true, at: t0 }) } });
    await step("open services", "stationRefusal", { peer: OTHER, workspace: WS });
    await step("added", "heard", { peer: OTHER, workspace: WS, request: { method: "rig.added", signed: owner.says("add", { v: 1, sub: "pat", ws: WS, rig: RIG, at: t0 }) } });
    await step("proof", "heard", { peer: OTHER, workspace: WS, request: { method: "rig.proof" } });
    await step("described with proof", "described");
    const now = secs(START + 1_864_000);
    await step("full", "heard", { peer: OTHER, workspace: WS, request: { method: "rig.full", signed: owner.says("full", { v: 1, sub: "pat", ws: WS, rig: RIG, at: now }) } });
    // a station new to the roster told it is here; out of the workspace, told nothing
    s.how(OTHER, "ok");
    await step("roster", "update", { set: { peers: [{ id: STATION }, { id: OTHER }, { id: "dd".repeat(32) }] } });
    await step("removed", "update", { set: { removed_at: 5 } });
    await step("no rig now", "self");
    await step("refused now", "guard", { workspace: WS, peer: STATION, request: prepare });
    t("files", await s.files());
  };
  const a: Json[] = [];
  await script(await tsRig(cloudData(state)), (l, v) => void a.push([l, v]));
  const b: Json[] = [];
  await script(await mbRig(cloudData(state)), (l, v) => void b.push([l, v]));
  server.close();
  assertSame(a, b);
});

// ── the workspace's rigs on a station ───────────────────────────────────────────────────────────────────────────

/// A rig as a station reaches it: how it says it is, what it takes and refuses, or away; every ask kept.
function rigFakes() {
  const asked: Json[] = [];
  const s = {
    asked,
    away: false,
    refuses: null as string | null,
    described: null as Json,
    proof: null as Json,
    until: 0,
    commands: [] as Json[],
    ask: async (rig: string, request: Json) => {
      asked.push([rig, request]);
      if (s.away) throw new Error("peer unavailable");
      if (s.refuses !== null && request.method !== "rig.describe" && request.method !== "rig.proof") throw new PeerRefused(s.refuses);
      switch (request.method) {
        case "rig.describe": return { tasks: true, rig: s.described };
        case "rig.proof": return { add: s.proof };
        case "rig.grant": return { until: s.until };
        case "rig.log": return { commands: s.commands };
        case "rig.add": throw new Error("away");
        default: return { ok: true };
      }
    },
  };
  return s;
}

/// The hub, its store and a chat's cards as a request asks them (rig-requests.test.ts's), every card and notice kept.
function hubFakes() {
  const cards: Json[] = [];
  const told: Json[] = [];
  const closed: Json[] = [];
  const tells: Json[] = [];
  const sessions = new Map<string, Json>([["s1", { ws: WS }], ["s2", { ws: WS }], ["s3", { ws: null }]]);
  const subscribers: ((c: Json) => void)[] = [];
  let n = 0;
  const thread = { connect: "c", thread: { id: 1, channel: "CHAT", threadTs: "1.0", surface: STILLFAIL_SURFACE } };
  const store: Json = {
    getSession: (k: string) => sessions.get(k) ?? null,
    starter: () => "lee@example.com",
    latestThread: () => thread,
    sessionThreadById: () => thread,
    insertMessage: (m: Json) => {
      cards.push({ ts: m.ts, text: m.text, card: m.card });
      return [++n];
    },
    pendingCardHeader: () => (cards.length === 0 ? null : [{ ts: cards.at(-1)!.ts }, cards.at(-1)!.card]),
    withdrawCard: (a: string, t: number, ts: string) => {
      told.push(["withdraw", a, t, ts]);
      return true;
    },
    restateCard: (_a: string, _t: number, ts: string, f: (was: Json) => Json) => {
      const c = cards.find((x) => x.ts === ts)!;
      c.card = f(c.card);
      return true;
    },
    subscribe: (f: Json) => void subscribers.push(f),
    sessionThread: () => null,
    sessionChat: () => null,
    firstText: () => null,
  };
  const hub: Json = { store, chat: () => ({ post: async () => `t${n + 1}` }), shared: () => {}, notify: (s: string, text: string) => void told.push([s, text]) };
  return { cards, told, closed, tells, sessions, store, hub, thread, subscribers };
}

test("the workspace's rigs on a station: asked, approved, brought, kept while away, taken back, listed, handed back", { skip }, async () => {
  const owner = person("pat");
  const RIGS = [{ id: RIG, name: "Build-Box", owner: "pat", owner_email: "Pat@Example.com", owner_name: "Pat" }, { id: "dd".repeat(32), name: "gpu", owner: "lee", owner_email: "", owner_name: "" }];
  const state = { station: STATION, workspace: WS, peers: [{ id: STATION, name: "here" }, { id: OTHER, name: "willow" }], rigs: RIGS };
  const viewer = (more: Json = {}) => ({ sub: "pat", email: "pat@example.com", name: "Pat", role: "member", workspace: WS, device: "d", ...more });
  const describedBy = (grants: Json[], more: Json = {}) => ({ owner: "pat", person: owner.genesis(), open: false, settings: 0, grants, devices: [{ id: "0123456789abcdef", name: "cam", kind: "tcp", target: "1.2.3.4:5", open: false, settings: 0 }], ...more });

  type RigsSide = {
    op(name: string, a?: Json): Promise<Json>;
    rig: ReturnType<typeof rigFakes>;
    hub: ReturnType<typeof hubFakes>;
    db(): Json;
    state(): Json;
  };

  async function tsRigs(data: string, dbPath: string): Promise<RigsSide> {
    const cloud = new Cloud(data, false);
    const rig = rigFakes();
    const h = hubFakes();
    const db = new DatabaseSync(dbPath);
    let tool: Json = null, routes: Json[] = [], heardRig: Json = null, rigAdd: Json = null, setRigs: Json = null, attached: Json = null;
    const sources: Json = { rigs: null, phones: null, forward: async (session: string, e: Json) => `forwarded ${e.id} for ${session}`, changed: null };
    const parts: Json = { tools: (t: Json[]) => void (tool = t[0]), routes: (r: Json[]) => void (routes = r) };
    const remote: Json = {
      ask: (id: string, request: Json) => rig.ask(id, request),
      bus: { whenAttached: (f: Json) => void (attached = f), on: (m: Json, f: Json) => void (Array.isArray(m) ? (heardRig = f) : (rigAdd = f)) },
      setRigs: (f: Json) => void (setRigs = f),
    };
    const forwards = { closeDevice: (s: string, d: string, why: string) => void h.closed.push([s, d, why]) };
    const events = { tell: (name: string, value: Json, key: string, scope: Json) => void h.tells.push([name, value, key, scope]) };
    const layer = RigsLive.pipe(Layer.provide(Layer.mergeAll(
      Layer.succeed(ControlPlane, { state: cloud } as Json),
      Layer.succeed(Parts, parts),
      Layer.succeed(Store, { ...h.store, db } as Json),
      Layer.succeed(Events, events as Json),
      Layer.succeed(Agents, { hub: h.hub, remote, forwards } as Json),
      Layer.succeed(DeviceSources, sources),
    )));
    const scope = Effect.runSync(Scope.make());
    await Effect.runPromise(Layer.buildWithScope(layer, scope));
    attached?.();
    const route = async (a: Json) => {
      const r = routes.find((x) => x.method === a.method && x.pattern.test(a.path));
      if (r === undefined) return null;
      const req: Request = { method: a.method, path: a.path, query: a.query ?? [], headers: {}, lang: "en", body: Buffer.from(a.body ?? ""), viewer: a.viewer } as Json;
      const answer = await r.handle(req, (r.pattern.exec(a.path) ?? []).slice(1));
      return { status: answer.status, body: String(answer.body) };
    };
    return {
      rig, hub: h,
      async op(name, a: Json = {}) {
        try {
          let v: unknown;
          switch (name) {
            case "look": cloud.rigsChanged(); v = undefined; break;
            case "heardRig": v = await heardRig(a.peer, a.request, a.workspace); break;
            case "rigAdd": v = await rigAdd(a.peer, a.request, a.workspace); break;
            case "tool": v = await tool.run(a.session, a.args); break;
            case "stationListed": v = await setRigs(a.workspace, a.session, a.rig, a.answer ?? null); break;
            case "deviceList": v = await sources.rigs.list(a.workspace, a.session); break;
            case "deviceUse": v = await sources.rigs.use(a.workspace, a.session, a.entry, a.reason, a.timeout ?? null); break;
            case "deviceDone": v = sources.rigs.done(a.workspace, a.session, a.entry ?? null); break;
            case "route": v = await route(a); break;
            case "archive":
              h.sessions.set(a.session, { ...h.sessions.get(a.session), archivedAt: 1 });
              for (const f of h.subscribers) f({ type: "session", key: a.session });
              v = undefined;
              break;
            case "update": cloud.update((st: Json) => Object.assign(st, a.set)); v = undefined; break;
            case "lock": cloud.takeLock(a.entries); v = undefined; break;
          }
          await settle();
          return { ok: norm(v) };
        } catch (e) {
          await settle();
          return { error: (e as Error).message };
        }
      },
      db: () => tables(db),
      state: () => {
        const s = JSON.parse(readFileSync(join(data, "mesh", "cloud.json"), "utf8"));
        return { rig_pending: s.rig_pending ?? null, rig_due: s.rig_due ?? null };
      },
    };
  }

  async function mbRigs(data: string, dbPath: string): Promise<RigsSide> {
    const p = program();
    const rig = rigFakes();
    const h = hubFakes();
    // what the program asks of the station: answered by fakes made as the TypeScript's are
    const twin: Json = {
      ...h.store,
      restateCard: async (_a: string, _t: number, ts: string, f: (was: Json) => Promise<Json>) => {
        const c = h.cards.find((x) => x.ts === ts)!;
        c.card = await f(c.card);
        return true;
      },
    };
    const hub = { ...h.hub, store: twin };
    p.world = async (name, args) => {
      const [kind, ...rest] = name.split(".");
      const what = rest.join(".");
      switch (kind) {
        case "store": return what === "has" ? typeof (twin as Json)[args[0]] === "function" : (twin as Json)[what](...args);
        case "hub": return what === "has" ? (hub as Json)[args[0]] != null : (hub as Json)[what](...args);
        case "remote": return rig.ask(args[0], args[1]);
        case "events": h.tells.push(args); return undefined;
        case "forwards": h.closed.push(args); return undefined;
        case "sources": return what === "hasForward" ? true : `forwarded ${args[1].id} for ${args[0]}`;
        case "dep":
          if (what === "postCard") return postCard(hub as Json, args[0], args[1], args[2], args[3], null);
          if (what === "cardPlace") return cardPlace(twin, args[0], args[1], args[2]);
          if (what === "grantChatTitle") return grantChatTitle(twin, args[0]);
      }
      throw new Error(`no world ${name}`);
    };
    await p.must("now", { ms: NOW });
    await p.must("mirror", { random: RANDOM });
    await p.must("cloud.open", { data });
    await p.must("rigs.new", { db: dbPath });
    await p.must("rigs.look");
    await p.must("settle");
    return {
      rig, hub: h,
      async op(name, a: Json = {}) {
        await p.must("now", { ms: NOW });
        let got: Json;
        switch (name) {
          case "look": got = await p.ask("rigs.look"); break;
          case "archive":
            h.sessions.set(a.session, { ...h.sessions.get(a.session), archivedAt: 1 });
            got = await p.ask("rigs.storeChanged", { change: { type: "session", key: a.session } });
            break;
          case "update": got = await p.ask("cloud.update", { set: a.set }); break;
          case "lock": got = await p.ask("cloud.takeLock", { entries: a.entries }); break;
          case "deviceDone": got = await p.ask("rigs.deviceDone", { session: a.session, ...(a.entry ? { entry: a.entry } : {}) }); break;
          default: got = await p.ask(`rigs.${name}`, a);
        }
        await p.must("settle");
        return "error" in got ? { error: got.error } : { ok: norm(got.ok) };
      },
      db: () => tables(new DatabaseSync(dbPath, { readOnly: true })),
      state: () => {
        const s = JSON.parse(readFileSync(join(data, "mesh", "cloud.json"), "utf8"));
        return { rig_pending: s.rig_pending ?? null, rig_due: s.rig_due ?? null };
      },
    };
  }

  const grantOf = (r: Json, timeout: Json = r.timeout) => owner.says("grant", { v: 1, sub: "pat", ws: WS, rig: RIG, station: STATION, session: r.session, chat: r.chat, request: r.id, title: r.title, by: r.by, timeout, at: secs(NOW), exp: latest(secs(NOW), timeout), ...(r.device ? { device: r.device } : {}) });

  const script = async (s: RigsSide, t: (label: string, v: Json) => void) => {
    const step = async (label: string, name: string, a: Json = {}) => {
      t(label, await s.op(name, a));
      t(`${label} asked`, s.rig.asked.splice(0));
      t(`${label} told`, s.hub.told.splice(0));
      t(`${label} closed`, s.hub.closed.splice(0));
      t(`${label} tells`, s.hub.tells.splice(0).map((x: Json) => [x[0], x[2], x[1]]));
      t(`${label} cards`, s.hub.cards.map((c: Json) => c.card?.rig?.outcome ?? null));
    };
    const route = (label: string, method: string, path: string, body: Json = undefined, v: Json = viewer(), query: Json[] = []) =>
      step(label, "route", { method, path, query, body: body === undefined ? "" : typeof body === "string" ? body : JSON.stringify(body), viewer: v });
    s.rig.described = describedBy([]);
    s.rig.until = secs(NOW) + 3600;
    await step("look", "look");
    await route("listed", "GET", "/rigs");
    await step("no station named", "tool", { session: "s1", args: { reason: "x" } });
    await step("unknown station", "tool", { session: "s1", args: { station: "nope", reason: "x" } });
    await step("no reason", "tool", { session: "s1", args: { station: "build-box", reason: " " } });
    await step("bad timeout", "tool", { session: "s1", args: { station: "build-box", reason: "x", timeout: { kind: "idle", seconds: 30 } } });
    await step("asked", "tool", { session: "s1", args: { station: "build-box", reason: "run the benchmark" } });
    t("card", s.hub.cards.map((c: Json) => [c.text, c.card]));
    await step("asked again", "tool", { session: "s1", args: { station: RIG, reason: "again" } });
    await step("station listed", "stationListed", { workspace: WS, session: "s1", rig: RIGS[0] });
    await route("listed asked", "GET", "/rigs");
    const r1 = JSON.parse((await s.op("route", { method: "GET", path: "/rigs", viewer: viewer() })).ok.body).rigs[0].requests[0];
    s.hub.tells.splice(0);
    const id1 = r1.id;
    await route("decided by another", "POST", `/rigs/requests/${id1}/decide`, { allow: true, signed: grantOf({ ...r1, ws: WS }), chain: owner.chain }, viewer({ sub: "lee" }));
    await route("decided elsewhere", "POST", `/rigs/requests/${id1}/decide`, { allow: true, signed: grantOf(r1) }, viewer({ workspace: "other" }));
    await route("signed otherwise", "POST", `/rigs/requests/${id1}/decide`, { allow: true, signed: grantOf({ ...r1, session: "s2" }) });
    await route("too large", "POST", `/rigs/requests/${id1}/decide`, { allow: true, signed: grantOf(r1), chain: ["x".repeat(600_000)] });
    await route("approved", "POST", `/rigs/requests/${id1}/decide`, { allow: true, signed: grantOf(r1, { kind: "fixed", seconds: 7200 }), chain: owner.chain });
    await route("decided twice", "POST", `/rigs/requests/${id1}/decide`, { allow: false });
    await route("not json", "POST", `/rigs/requests/${id1}/decide`, "{");
    await step("station listed granted", "stationListed", { workspace: WS, session: "s1", rig: RIGS[0] });
    // the rig says how it is: this station's grant it lists held, one it no longer lists ended
    await step("hello", "heardRig", { peer: RIG, workspace: WS, request: { method: "rig.hello", rig: describedBy([{ request: id1, station: STATION, session: "s1", chat: "CHAT/1.0", title: "", by: "lee@example.com", timeout: { kind: "fixed", seconds: 7200 }, exp: secs(NOW) + 7200, until: secs(NOW) + 7000 }]) } });
    await step("not a rig", "heardRig", { peer: OTHER, workspace: WS, request: { method: "rig.hello" } });
    await step("listed by the rig", "stationListed", { workspace: WS, session: "s2", rig: RIGS[0], answer: { rig: describedBy([{ request: id1, station: STATION, session: "s1", chat: "CHAT/1.0", title: "a chat", by: "lee", timeout: { kind: "fixed", seconds: 7200 }, exp: 1, until: 1_900_000_000 }]) } });
    await step("ended there", "heardRig", { peer: RIG, workspace: WS, request: { method: "rig.changed", rig: describedBy([]), ended: { request: id1, station: STATION, why: "expired" } } });
    // away: approved, then brought as it is heard; what its person signed meanwhile waits in the outbox
    NOW += 1000;
    await step("asked s2", "tool", { session: "s2", args: { station: "build-box", reason: "a build", timeout: { kind: "fixed", seconds: 600 } } });
    const r2 = JSON.parse((await s.op("route", { method: "GET", path: "/rigs", viewer: viewer() })).ok.body).rigs[0].requests.find((x: Json) => x.session === "s2");
    s.hub.tells.splice(0);
    s.rig.away = true;
    await route("approved away", "POST", `/rigs/requests/${r2.id}/decide`, { allow: true, signed: grantOf(r2), chain: owner.chain });
    await route("settings away", "POST", `/rigs/${RIG}/settings`, { signed: owner.says("settings", { v: 1, sub: "pat", ws: WS, rig: RIG, seq: 1, open: true, at: secs(NOW) }), chain: owner.chain });
    await route("settings again away", "POST", `/rigs/${RIG}/settings`, { signed: owner.says("settings", { v: 1, sub: "pat", ws: WS, rig: RIG, seq: 2, open: false, at: secs(NOW) }) });
    await route("settings by another", "POST", `/rigs/${RIG}/settings`, { signed: owner.says("settings", { v: 1, sub: "pat", ws: WS, rig: RIG, seq: 3, open: true, at: secs(NOW) }) }, viewer({ sub: "lee" }));
    await route("settings not its", "POST", `/rigs/${RIG}/settings`, { signed: owner.says("settings", { v: 1, sub: "pat", ws: "x", rig: RIG, seq: 3, open: true, at: secs(NOW) }) });
    await route("device away", "POST", `/rigs/${RIG}/devices`, { signed: owner.says("device", { v: 1, sub: "pat", ws: WS, rig: RIG, device: { id: "0123456789abcdef", name: "cam", kind: "tcp", target: "1.2.3.4:5" }, removed: false, at: secs(NOW) }) });
    await route("log away", "GET", `/rigs/${RIG}/log`);
    t("outbox", s.db().rig_outbox);
    s.rig.away = false;
    s.rig.until = secs(NOW) + 600;
    await step("back", "heardRig", { peer: RIG, workspace: WS, request: { method: "rig.hello", rig: describedBy([]) } });
    t("outbox after", s.db().rig_outbox);
    // refused there: final, the next brought
    s.rig.refuses = "older than the settings this rig has";
    await route("refused there", "POST", `/rigs/${RIG}/settings`, { signed: owner.says("settings", { v: 1, sub: "pat", ws: WS, rig: RIG, seq: 1, open: true, at: secs(NOW) }) });
    s.rig.refuses = null;
    s.rig.commands = [{ at: 1, station: STATION, session: "s1", key: "k", name: "b", command: "make", kind: "task" }, { at: 2, station: "ee".repeat(32) }, 5];
    await route("log", "GET", `/rigs/${RIG}/log`, undefined, viewer(), [["limit", "7"]]);
    await route("log limit", "GET", `/rigs/${RIG}/log`, undefined, viewer(), [["limit", "x"]]);
    await route("log of none", "GET", `/rigs/${"ab".repeat(32)}/log`);
    // taken back: its own grant by the request; another station's chat's by the rig
    const granted = JSON.parse((await s.op("route", { method: "GET", path: "/rigs", viewer: viewer() })).ok.body).rigs[0];
    s.hub.tells.splice(0);
    t("granted listed", granted);
    const revoke = (request: string, more: Json = {}) => owner.says("revoke", { v: 1, sub: "pat", ws: WS, rig: RIG, request, at: secs(NOW), ...more });
    await route("revoke by another", "POST", `/rigs/requests/${r2.id}/revoke`, { signed: revoke(r2.id) }, viewer({ sub: "lee" }));
    await route("revoke not its", "POST", `/rigs/requests/${r2.id}/revoke`, { signed: revoke("other") });
    await route("revoked", "POST", `/rigs/requests/${r2.id}/revoke`, { signed: revoke(r2.id), chain: owner.chain });
    await route("revoke elsewhere", "POST", `/rigs/requests/remote1/revoke`, { rig: "build-box", signed: revoke("remote1") });
    await route("revoke elsewhere not its", "POST", `/rigs/requests/remote1/revoke`, { rig: "build-box", signed: revoke("remote2") });
    await route("revoke elsewhere no rig", "POST", `/rigs/requests/remote1/revoke`, { signed: revoke("remote1") });
    // refused, handed back, archived
    NOW += 1000;
    await step("asked s1 again", "tool", { session: "s1", args: { station: "build-box", reason: "three" } });
    await step("handed back", "tool", { session: "s1", args: { done: true } });
    await step("handed back none", "tool", { session: "s1", args: { done: true, station: "build-box" } });
    NOW += 1000;
    await step("asked s2 again", "tool", { session: "s2", args: { station: "build-box", reason: "four" } });
    await step("archived", "archive", { session: "s2" });
    await step("archived asks nothing", "tool", { session: "s2", args: { station: "build-box", reason: "five" } });
    await step("no workspace", "tool", { session: "s9", args: { station: "build-box", reason: "x" } });
    // devices of the rig
    s.rig.described = describedBy([]);
    await step("described again", "heardRig", { peer: RIG, workspace: WS, request: { method: "rig.changed", rig: describedBy([]) } });
    await step("devices", "deviceList", { workspace: WS, session: "s1" });
    const entry = { id: "0123456789abcdef", name: "cam", station: RIG };
    NOW += 1000;
    await step("device asked", "deviceUse", { workspace: WS, session: "s1", entry, reason: "look at it", timeout: { kind: "fixed", seconds: 600, extra: 1 } });
    await step("devices asked", "deviceList", { workspace: WS, session: "s1" });
    await step("device done", "deviceDone", { workspace: WS, session: "s1", entry });
    await step("devices done all", "deviceDone", { workspace: WS, session: "s1" });
    await step("device open", "heardRig", { peer: RIG, workspace: WS, request: { method: "rig.changed", rig: describedBy([], { devices: [{ id: "0123456789abcdef", name: "cam", kind: "tcp", target: "1.2.3.4:5", open: true, settings: 1 }] }) } });
    await step("device forwarded", "deviceUse", { workspace: WS, session: "s1", entry, reason: "x" });
    await step("open to all", "heardRig", { peer: RIG, workspace: WS, request: { method: "rig.changed", rig: describedBy([], { open: true }) } });
    await step("no grant needed", "tool", { session: "s1", args: { station: "build-box", reason: "x" } });
    await step("listed open", "stationListed", { workspace: WS, session: "s1", rig: RIGS[0] });
    // whole again, and a whole station to run only tasks
    await route("full by another", "POST", `/rigs/${RIG}/full`, { signed: owner.says("full", { v: 1, sub: "pat", ws: WS, rig: RIG, at: secs(NOW) }) }, viewer({ sub: "lee" }));
    await route("full not a manager", "POST", `/rigs/${RIG}/full`, { signed: owner.says("full", { v: 1, sub: "pat", ws: WS, rig: RIG, at: secs(NOW) }) });
    await route("full", "POST", `/rigs/${RIG}/full`, { signed: owner.says("full", { v: 1, sub: "pat", ws: WS, rig: RIG, at: secs(NOW) }), chain: owner.chain }, viewer({ role: "admin" }));
    s.rig.refuses = "signed too long ago: switch it again";
    await route("full refused", "POST", `/rigs/${RIG}/full`, { signed: owner.says("full", { v: 1, sub: "pat", ws: WS, rig: RIG, at: secs(NOW) }) }, viewer({ role: "owner" }));
    s.rig.refuses = null;
    s.rig.away = true;
    await route("full away", "POST", `/rigs/${RIG}/full`, { signed: owner.says("full", { v: 1, sub: "pat", ws: WS, rig: RIG, at: secs(NOW) }) }, viewer({ role: "owner" }));
    s.rig.away = false;
    await route("mode bad", "POST", "/mode", { mode: "tasks", person: "x" });
    await route("mode", "POST", "/mode", { mode: "tasks", person: "ee".repeat(32) }, viewer({ name: undefined }));
    t("mode kept", s.state());
    await route("no route", "POST", "/rigs/x/y");
    await route("add not in security mode", "POST", `/rigs/${RIG}/add`, { signed: owner.says("add", { v: 1, sub: "pat", ws: WS, rig: RIG, at: secs(NOW) }) });
    await route("add none", "POST", `/rigs/${"ab".repeat(32)}/add`, {});
    await route("add by another", "POST", `/rigs/${RIG}/add`, {}, viewer({ sub: "lee" }));
    await step("rig.add elsewhere", "rigAdd", { peer: OTHER, workspace: WS, request: { rig: RIG, signed: null } });
    await step("rig.add none", "rigAdd", { peer: OTHER, workspace: WS, request: { rig: "ab".repeat(32) } });
    t("tables", s.db());
  };
  NOW = START;
  const a: Json[] = [];
  await script(await tsRigs(cloudData(state), join(fresh("rigs-ts-"), "stillfail.db")), (l, v) => void a.push([l, v]));
  NOW = START;
  const b: Json[] = [];
  await script(await mbRigs(cloudData(state), join(fresh("rigs-mb-"), "stillfail.db")), (l, v) => void b.push([l, v]));
  assertSame(a, b);
});

test("security mode on a station: a rig is taken once its person signed for it, and goes with them", { skip }, async () => {
  const owner = person("pat");
  const alice = { sub: "alice", signer: ed(), base: ed() };
  const pat = { sub: "pat", signer: ed(), base: ed() };
  const g = sealed({ v: 1, ws: WS, seq: 0, prev: null, at: 1000, kind: "genesis", body: {
    owner: "alice", origins: ["https://app.still.fail"], rp_id: "app.still.fail", cloud_keys: { keys: [] },
    members: [{ sub: "alice", email: "a@x", role: "owner" }, { sub: "pat", email: "p@x", role: "member" }],
    devices: [alice, pat].map((d) => ({ id: d.base.hex, sub: d.sub, kind: "app", label: d.sub, sign_key: d.signer.id })),
    passkeys: [], stations: [{ key: STATION, name: "here" }], gateways: [],
  } } as Json, alice.signer);
  const removal = sealed({ v: 1, ws: WS, seq: 1, prev: entryHash(g), at: 2500, kind: "member.remove", body: { sub: "pat" } } as Json, alice.signer);
  const RIGS = [{ id: RIG, name: "box", owner: "pat", owner_email: "p@x", owner_name: "Pat" }];
  const state = { station: STATION, workspace: WS, peers: [{ id: STATION }, { id: OTHER }], rigs: RIGS };
  const add = (by: Key) => ({ body: { v: 1, sub: "pat", ws: WS, rig: RIG, at: 2000 }, sig: { key: by.id, sig: by.sign(signedBytes("add", { v: 1, sub: "pat", ws: WS, rig: RIG, at: 2000 }, sha256)) } });
  const run = async (mb: boolean) => {
    const data = cloudData(state);
    const t: Json[] = [];
    const rig = rigFakes();
    rig.described = { owner: "pat", person: owner.genesis(), open: false, settings: 0, grants: [] };
    const tells: Json[] = [];
    const dbPath = join(fresh("rigs-sec-"), "stillfail.db");
    if (!mb) {
      const cloud = new Cloud(data, false);
      cloud.takeLock([g]);
      const h = hubFakes();
      let routes: Json[] = [], rigAdd: Json = null, attached: Json = null;
      const layer = RigsLive.pipe(Layer.provide(Layer.mergeAll(
        Layer.succeed(ControlPlane, { state: cloud } as Json),
        Layer.succeed(Parts, { tools: () => {}, routes: (r: Json[]) => void (routes = r) } as Json),
        Layer.succeed(Store, { ...h.store, db: new DatabaseSync(dbPath) } as Json),
        Layer.succeed(Events, { tell: (...x: Json[]) => void tells.push(x[1].rigs) } as Json),
        Layer.succeed(Agents, { hub: h.hub, remote: { ask: rig.ask, bus: { whenAttached: (f: Json) => void (attached = f), on: (m: Json, f: Json) => void (!Array.isArray(m) && (rigAdd = f)) }, setRigs: () => {} }, forwards: { closeDevice: () => {} } } as Json),
        Layer.succeed(DeviceSources, { rigs: null } as Json),
      )));
      await Effect.runPromise(Layer.buildWithScope(layer, Effect.runSync(Scope.make())));
      attached();
      await settle();
      const route = async (path: string, body: Json) => {
        const r = routes.find((x) => x.pattern.test(path) && x.method === "POST")!;
        const a = await r.handle({ method: "POST", path, query: [], headers: {}, lang: "en", body: Buffer.from(JSON.stringify(body)), viewer: { sub: "pat", role: "member", workspace: WS } } as Json, (r.pattern.exec(path) ?? []).slice(1));
        await settle();
        return { status: a.status, body: String(a.body) };
      };
      t.push(["met", rig.asked.splice(0), tells.splice(0)]);
      t.push(["stranger", await route(`/rigs/${RIG}/add`, { signed: add(ed()) })]);
      t.push(["added", await route(`/rigs/${RIG}/add`, { signed: add(pat.signer) }), rig.asked.splice(0), tells.splice(0)]);
      t.push(["rig.add", await rigAdd(OTHER, { rig: RIG, signed: add(pat.signer) }, WS).catch(errorOf)]);
      await settle();
      t.push(["after", rig.asked.splice(0), tells.splice(0).at(-1)]);
      cloud.takeLock([g, removal]);
      await settle();
      t.push(["removed", tells.splice(0).at(-1), rig.asked.splice(0)]);
      t.push(["outbox", tables(new DatabaseSync(dbPath, { readOnly: true }))]);
    } else {
      const p = program();
      p.world = async (name, args) => {
        if (name === "remote.ask") return rig.ask(args[0], args[1]);
        if (name === "events.tell") return void tells.push(args[1].rigs);
        if (name === "dep.grantChatTitle") return null;
        throw new Error(`no world ${name}`);
      };
      await p.must("now", { ms: NOW });
      await p.must("cloud.open", { data });
      await p.must("cloud.takeLock", { entries: [g] });
      await p.must("rigs.new", { db: dbPath });
      await p.must("rigs.look");
      await p.must("settle");
      const route = async (path: string, body: Json) => {
        const got = await p.must("rigs.route", { method: "POST", path, query: [], body: JSON.stringify(body), viewer: { sub: "pat", role: "member", workspace: WS } });
        await p.must("settle");
        return got;
      };
      t.push(["met", rig.asked.splice(0), tells.splice(0)]);
      t.push(["stranger", await route(`/rigs/${RIG}/add`, { signed: add(ed()) })]);
      t.push(["added", await route(`/rigs/${RIG}/add`, { signed: add(pat.signer) }), rig.asked.splice(0), tells.splice(0)]);
      const got = await p.ask("rigs.rigAdd", { peer: OTHER, workspace: WS, request: { rig: RIG, signed: add(pat.signer) } });
      t.push(["rig.add", "error" in got ? { error: got.error } : got.ok]);
      await p.must("settle");
      t.push(["after", rig.asked.splice(0), tells.splice(0).at(-1)]);
      await p.must("cloud.takeLock", { entries: [g, removal] });
      await p.must("settle");
      t.push(["removed", tells.splice(0).at(-1), rig.asked.splice(0)]);
      t.push(["outbox", tables(new DatabaseSync(dbPath, { readOnly: true }))]);
    }
    return t;
  };
  NOW = START;
  const a = await run(false);
  NOW = START;
  const b = await run(true);
  // (a signature is made anew for a stranger each run: its refusal is the same words)
  assertSame(a, b);
});

/// Every row of the rigs' tables, in order.
function tables(db: DatabaseSync): Json {
  const of = (t: string, order: string) => {
    try {
      return db.prepare(`SELECT * FROM ${t} ORDER BY ${order}`).all();
    } catch {
      return null;
    }
  };
  return { rig_outbox: of("rig_outbox", "n"), rig_requests: of("rig_requests", "id"), rig_adds: of("rig_adds", "ws, rig") };
}

// ── running as administrator ────────────────────────────────────────────────────────────────────────────────────

/// A station's data and app, as install.ps1 leaves them (its hidden launcher there).
function installed(windows?: unknown, leaf?: string) {
  let data = mkdtempSync(join(tmpdir(), "stillfail-elevation-"));
  dirs.push(data);
  if (leaf !== undefined) mkdirSync((data = join(data, leaf)));
  const app = join(data, "app");
  mkdirSync(join(app, "mesh", "target", "release"), { recursive: true });
  writeFileSync(join(app, "mesh", "target", "release", "stillfail-station-w.exe"), "");
  mkdirSync(join(data, "run"));
  if (windows !== undefined) writeFileSync(join(data, "windows.json"), JSON.stringify(windows));
  return { data, app };
}

type ElevSide = {
  op(name: string, a?: Json): Promise<Json>;
  write(path: string, text: string): void;
  events(): Promise<Json[]>;
  files(): Json;
};

test("running as administrator: what the overview says, a change asked, refused, unanswered, applied, restarted; PUT /elevation", { skip }, async () => {
  const words = { zh: Object.fromEntries(Object.entries(zhStation).filter(([k]) => k.startsWith("station.elevation."))), en: Object.fromEntries(Object.entries(enStation).filter(([k]) => k.startsWith("station.elevation."))) };
  const filesOf = (data: string) => {
    const run = join(data, "run");
    const f: Json = {};
    for (const name of readdirSync(run).sort()) f[name] = readFileSync(join(run, name), "utf8").replaceAll(data, "<data>");
    f.windows = existsSync(join(data, "windows.json")) ? readFileSync(join(data, "windows.json"), "utf8") : null;
    return f;
  };

  async function tsElev(paths: { data: string; app: string }, probe: Json): Promise<ElevSide> {
    let now = 1_000_000;
    const timers: { at: number; f: () => void; off: boolean }[] = [];
    const events: Json[] = [];
    const children: (EventEmitter & Json)[] = [];
    const e = new Elevation({
      ...paths,
      now: () => now,
      after: (ms, f) => {
        const t = { at: now + ms, f, off: false };
        timers.push(t);
        return () => void (t.off = true);
      },
      changed: () => void events.push(["changed"]),
      probe: async () => probe,
      run: (script) => {
        const child = new EventEmitter() as Json;
        const id = children.length + 1;
        child.kill = () => void events.push(["kill", id]);
        children.push(child);
        events.push(["run", id, script.replaceAll(paths.data, "<data>")]);
        return child;
      },
    });
    const pass = async (ms: number) => {
      const end = now + ms;
      for (;;) {
        const next = timers.filter((t) => !t.off && t.at <= end).sort((a, b) => a.at - b.at)[0];
        if (next === undefined) break;
        now = Math.max(now, next.at);
        next.off = true;
        next.f();
        await e.settled();
      }
      now = end;
    };
    const [route] = elevationRoutes(e);
    return {
      async op(name, a: Json = {}) {
        try {
          let v: unknown;
          switch (name) {
            case "start": v = await e.start(); break;
            case "view": v = e.view(a.manage); break;
            case "change": v = await e.change(a.on); break;
            case "exit": children[a.child - 1]!.emit("exit", a.code); break;
            case "error": children[a.child - 1]!.emit("error", new Error("spawn")); break;
            case "pass": await pass(a.ms); break;
            case "stop": v = await e.stop(); break;
            case "on": v = e.on(); break;
            case "route": {
              const r: Request = { method: "PUT", path: "/elevation", query: [], headers: {}, lang: a.lang, body: Buffer.from(a.body), viewer: a.viewer } as Json;
              const answer = await route!.handle(r, []);
              v = { status: answer.status, body: String(answer.body) };
              break;
            }
          }
          await e.settled();
          return { ok: norm(v) };
        } catch (err) {
          await e.settled();
          return { error: (err as Error).message, ...((err as Json).key !== undefined ? { key: (err as Json).key } : {}) };
        }
      },
      write: (path, text) => writeFileSync(join(paths.data, path), text),
      events: async () => events.splice(0),
      files: () => filesOf(paths.data),
    };
  }

  async function mbElev(paths: { data: string; app: string }, probe: Json): Promise<ElevSide> {
    const p = program();
    p.world = async (name) => {
      if (name === "probe") return probe;
      throw new Error(`no world ${name}`);
    };
    await p.must("words", words);
    await p.must("now", { ms: 1_000_000 });
    await p.must("elev.new", paths);
    return {
      async op(name, a: Json = {}) {
        const map: Record<string, string> = { start: "elev.start", view: "elev.view", change: "elev.change", exit: "elev.exit", error: "elev.error", pass: "pass", stop: "elev.stop", on: "elev.on", route: "elev.route" };
        const got = await p.ask(map[name]!, name === "route" ? { ...a, method: "PUT", path: "/elevation" } : a);
        await p.must("settle");
        return "error" in got ? { error: got.error, ...(got.key !== undefined ? { key: got.key } : {}) } : { ok: norm(got.ok) };
      },
      write: (path, text) => writeFileSync(join(paths.data, path), text),
      events: async () => (await p.must("events")).map((e: Json) => (e[0] === "run" ? [e[0], e[1], e[2].replaceAll(paths.data, "<data>")] : e)),
      files: () => filesOf(paths.data),
    };
  }

  type Case = { windows?: unknown; leaf?: string; before?: [string, string][]; probe: Json; script: (s: ElevSide, t: (l: string, v: Json) => void) => Promise<void> };
  const viewerOf = (role: string) => ({ sub: "s", email: "m@x.com", name: "M", role, workspace: "ws", device: "d" });
  const cases: Record<string, Case> = {
    overview: { windows: { admin: true }, probe: { elevated: true, admin: true }, script: async (s, t) => {
      t("view", await s.op("view", { manage: true }));
      t("on", await s.op("on"));
    } },
    "not an administrator": { probe: { elevated: false, admin: false }, script: async (s, t) => {
      t("view", await s.op("view", { manage: false }));
      t("change", await s.op("change", { on: true }));
    } },
    declined: { windows: { task: "apart" }, probe: { elevated: false, admin: true }, script: async (s, t) => {
      t("change", await s.op("change", { on: true }));
      t("asking", await s.op("view", { manage: true }));
      t("busy", await s.op("change", { on: false }));
      t("files", s.files());
      t("declined", await s.op("exit", { child: 1, code: 4 }));
      t("after", await s.op("view", { manage: true }));
      t("stop", await s.op("stop"));
    } },
    // install.ps1 writes no windows.json for monoid's own task: the data directory says whose it is.
    monoid: { leaf: ".monoid", probe: { elevated: false, admin: true }, script: async (s, t) => {
      t("change", await s.op("change", { on: true }));
      t("files", s.files());
    } },
    "monoid apart": { leaf: ".monoid", windows: { task: "apart" }, probe: { elevated: false, admin: true }, script: async (s, t) => {
      t("change", await s.op("change", { on: true }));
      t("files", s.files());
    } },
    unanswered: { probe: { elevated: false, admin: true }, script: async (s, t) => {
      t("change", await s.op("change", { on: true }));
      t("pass", await s.op("pass", { ms: ASK_MS - 1 }));
      t("still", await s.op("view", { manage: true }));
      t("pass", await s.op("pass", { ms: 1 }));
      t("unanswered", await s.op("view", { manage: true }));
      t("files", s.files());
    } },
    "failed to start": { probe: { elevated: false, admin: true }, script: async (s, t) => {
      t("change", await s.op("change", { on: true }));
      t("error", await s.op("error", { child: 1 }));
      t("view", await s.op("view", { manage: true }));
      t("exit after", await s.op("exit", { child: 1, code: 5 }));
      t("view after", await s.op("view", { manage: true }));
    } },
    applied: { probe: { elevated: false, admin: true }, script: async (s, t) => {
      t("change", await s.op("change", { on: true }));
      t("answered", await s.op("exit", { child: 1, code: 0 }));
      s.write("run/elevation.json", JSON.stringify({ want: true, at: 1, step: "applying" }));
      t("pass", await s.op("pass", { ms: 1000 }));
      t("applying", await s.op("view", { manage: true }));
      t("pass", await s.op("pass", { ms: 60_000 }));
      t("over", await s.op("view", { manage: true }));
      t("again", await s.op("change", { on: true }));
    } },
    restarting: { windows: { admin: false, task: "" }, probe: { elevated: false, admin: true }, script: async (s, t) => {
      t("change", await s.op("change", { on: true }));
      t("answered", await s.op("exit", { child: 1, code: 0 }));
      s.write("run/elevation.json", "\uFEFF" + JSON.stringify({ want: true, at: 1, step: "restarting" }));
      s.write("windows.json", "\uFEFF" + JSON.stringify({ admin: true, task: "x" }));
      t("pass", await s.op("pass", { ms: 120_000 }));
      t("restarting", await s.op("view", { manage: true }));
      t("on", await s.op("on"));
    } },
    "elevated goes back": { windows: { admin: true }, probe: { elevated: true, admin: false }, script: async (s, t) => {
      t("change", await s.op("change", { on: false }));
      t("files", s.files());
      t("stop", await s.op("stop"));
    } },
    "already as wanted": { probe: { elevated: true, admin: true }, script: async (s, t) => {
      t("change", await s.op("change", { on: true }));
      t("files", s.files());
    } },
    "restarted as wanted": { windows: { admin: true }, before: [["run/elevation.json", JSON.stringify({ want: true, at: 1, step: "restarting" })]], probe: { elevated: true, admin: true }, script: async (s, t) => {
      t("view", await s.op("view", { manage: true }));
    } },
    "restarted not as wanted": { before: [["run/elevation.json", JSON.stringify({ want: true, at: 1, step: "restarting", message: "x" })]], probe: { elevated: false, admin: true }, script: async (s, t) => {
      t("view", await s.op("view", { manage: true }));
      t("files", s.files());
    } },
    "a process gone": { before: [["run/elevation.json", JSON.stringify({ want: true, at: 1, step: "asking" })]], probe: { elevated: false, admin: true }, script: async (s, t) => {
      t("view", await s.op("view", { manage: true }));
    } },
    "failed before": { before: [["run/elevation.json", JSON.stringify({ want: false, at: 1, failed: "error", message: "nope" })], ["windows.json", "not json"]], probe: { elevated: false, admin: true }, script: async (s, t) => {
      t("view", await s.op("view", { manage: false }));
    } },
    "not installed": { probe: { elevated: false, admin: true }, script: async (s, t) => {
      t("change", await s.op("change", { on: true }));
    } },
    route: { probe: { elevated: false, admin: true }, script: async (s, t) => {
      for (const [lang, role, body] of [["en", "member", '{"on":true}'], ["zh", "member", '{"on":true}'], ["en", "owner", "{"], ["en", "owner", '{"on":"yes"}'], ["en", "owner", ""], ["en", "owner", "null"], ["en", "admin", '{"on":true}'], ["zh", "owner", '{"on":false}'], ["en", "owner", '{"on":false}']]) {
        t(`${lang} ${role} ${body}`, await s.op("route", { lang, body, viewer: viewerOf(role!) }));
      }
    } },
  };
  for (const [name, c] of Object.entries(cases)) {
    const run = async (make: typeof tsElev) => {
      const paths = installed(c.windows, c.leaf);
      if (name === "not installed") rmSync(join(paths.app, "mesh", "target", "release", "stillfail-station-w.exe"));
      for (const [path, text] of c.before ?? []) writeFileSync(join(paths.data, path), text);
      const s = await make(paths, c.probe);
      const t: Json[] = [];
      t.push(["start", await s.op("start")]);
      await c.script(s, (l, v) => void t.push([l, v]));
      t.push(["events", await s.events()]);
      t.push(["files", s.files()]);
      return t;
    };
    const a = await run(tsElev);
    const b = await run(mbElev);
    if (name === "monoid") for (const side of [a, b]) assert.match(JSON.stringify(side), /Level 'monoid station' 'Highest'[\s\S]*-TaskName 'monoid station elevation'/, name);
    assert.equal(b.length, a.length, name);
    for (let i = 0; i < a.length; i++) assert.deepEqual(b[i], a[i], `${name}: step ${i} ${JSON.stringify(a[i]).slice(0, 160)}`);
  }
});
