// The phones lent to the station and the workspace's devices in MoonBit (station/mb src/adb_devices: reader `--builder
// harness-adb-devices`) held to the TypeScript they are written from (src/adb/*.ts, src/devices/*.ts). Each case is
// given to both, each on a world of its own made the same (its own database, its own fake adb and its directory, its
// own clock, its own phone in memory), and what each answered, said, asked of its world and left in it is compared:
// what adb's frames make of use, a refusal adb's client reads, what scrcpy and SurfaceFlinger say read, the agents'
// tools' words, a chat's grants asked, decided, used, linked and ended on twin databases (their cards, notices and rows),
// a grant named by its chat, the door's gate and the door itself, devices kept and refused, a file staged and fetched by
// the phone, the grants' adb servers a station before left, a phone's offer over its link with its tunnels, pairing and
// grant (fake adb), a chat's display on the phone, and the phones' and devices' parts as the station runs them.
import assert from "node:assert/strict";
import { type ChildProcess, type ChildProcessWithoutNullStreams, spawn } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import { mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, watch, writeFileSync } from "node:fs";
import { copyFile, mkdir, readFile, realpath, rename, rm, stat, writeFile } from "node:fs/promises";
import net from "node:net";
import { DatabaseSync } from "node:sqlite";
import { tmpdir } from "node:os";
import { delimiter, join } from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";
import { after, test } from "node:test";
import type { Clock } from "effect";
import zhStation from "../../client/i18n/catalog/zh/station.json" with { type: "json" };
import enStation from "../../client/i18n/catalog/en/station.json" with { type: "json" };
import { chatTitle } from "../../client/core-ts/src/titles.ts";
import { AdbActivity, DISPLAY_MARK, KEEP_LENDING } from "../src/adb/activity.ts";
import { PhoneDisplays, densityOf, displayOf, rootTasksOn, surfaceOf } from "../src/adb/displays.ts";
import { failure, gate, type GateDeps, openDoor } from "../src/adb/door.ts";
import { PhoneGrants, type PhoneRequest, linkSaid, said, scopeSaid } from "../src/adb/grants.ts";
import { Shares, answerAdb, isPackage, key, text, usualPort } from "../src/adb/link.ts";
import { fetchOnPhone, staged } from "../src/adb/send.ts";
import { GrantServers } from "../src/adb/servers.ts";
import { grantChatTitle } from "../src/adb/title.ts";
import { ADB_DEVICES, PHONE_SEND, PHONE_USE, displayed, listed, phoneTools, reached } from "../src/adb/tool.ts";
import { hostPort } from "../src/devices/connect.ts";
import { DeviceRegistry } from "../src/devices/registry.ts";
import { DEVICE_LIST, DEVICE_USE, deviceTools, reachedAt } from "../src/devices/tool.ts";
import { deviceRefusal } from "../../client/core-ts/src/rig-form.ts";
import { langOfCore } from "../src/api/request.ts";
import { wall } from "../src/ops/fibers.ts";
import { setStationLang } from "../src/ops/i18n.ts";
import { sizeOf } from "../src/screens/android.ts";
import { mbReaderBinary } from "../src/read/mb-reader.ts";
import { MessageWriteBusy, STILLFAIL_SURFACE } from "../src/store/store.ts";
import { exe, script } from "./accounts-fakes.ts";
import { log } from "../src/ops/log.ts";
import { platform } from "../src/platform/index.ts";
import { Duration, Effect, Exit, Layer, Scope } from "effect";
import { DevicesLive } from "../src/devices/module.ts";
import { AdbLive } from "../src/adb/module.ts";
import { Refused as PeerRefused } from "../src/mesh/bus.ts";
import * as services from "../src/services.ts";
import { Agents } from "../src/sessions/agents.ts";
import { childGone } from "./child-gone.ts";

type Json = any;
const binary = mbReaderBinary();
assert.ok(binary !== null, "the MoonBit program (stillfail-reader) is built: sh station/mb/build.sh");

const dirs: string[] = [];
const fresh = (what: string) => {
  const dir = mkdtempSync(join(tmpdir(), `mb-adb-${what}-`));
  dirs.push(dir);
  return dir;
};
const plain = (v: unknown) => (v === undefined ? null : JSON.parse(JSON.stringify(v)));
/// Some turns of the loop: what was set going in this process has gone on as far as it goes without the world. `n` of
/// them with no file request out, as hub-fakes.ts `settle`: the TypeScript's servers, links and door read and write
/// their files on libuv's threads, and how many turns that takes is the machine's.
const turn = async (n = 20) => {
  for (let quiet = 0; quiet < n; ) {
    await new Promise((r) => setImmediate(r));
    // (a file handle's close, the last step of fs/promises' writeFile and readFile, is a request of its own: CloseReq)
    quiet = process.getActiveResourcesInfo().some((r) => r === "FSReqPromise" || r === "FSReqCallback" || r === "CloseReq") ? 0 : quiet + 1;
  }
};

// ── a clock of a test's own, one each side ──

const T0 = 1_800_000_000_000;

/// The test's time: waits come due as it is moved on, in the order they are due.
class TestTime {
  now = T0;
  #next = 0;
  readonly sleepers = new Map<number, { due: number; ms: number; done: (v?: unknown) => void }>();
  #heard: (() => void)[] = [];
  /// Whether a wait comes due by itself, the clock moved on to it (for a case where waits are only a writer's).
  auto = false;
  /// The waits that come due by themselves, by how long they are (null: all).
  autoOnly: number[] | null = null;
  /// What a wait coming due by itself waits for first (what the machine is to have done by then).
  gate: () => Promise<void> = async () => {};
  /// `f` once `ms` from now; called off by what is returned.
  after(ms: number, f: (v?: unknown) => void, id = --this.#next): () => void {
    this.sleepers.set(id, { due: this.now + Math.max(0, ms), ms, done: f });
    for (const h of this.#heard.splice(0)) h();
    if (this.auto && (this.autoOnly === null || this.autoOnly.includes(ms))) setImmediate(() => void this.gate().then(() => this.done(id)));
    return () => void this.sleepers.delete(id);
  }
  /// Wait `id` come due now, the clock moved on to it (`auto`).
  async done(id: number) {
    const s = this.sleepers.get(id);
    if (s === undefined) return;
    this.sleepers.delete(id);
    this.now = Math.max(this.now, s.due);
    s.done();
  }
  cancel(id: number) {
    const s = this.sleepers.get(id);
    this.sleepers.delete(id);
    s?.done("cancelled");
  }
  /// The waits under way, by how long each was.
  waiting(): number[] {
    return [...this.sleepers.values()].map((s) => s.ms).sort((a, b) => a - b);
  }
  /// Done once a wait of `ms` is under way.
  async waitFor(ms: number): Promise<void> {
    while (![...this.sleepers.values()].some((s) => s.ms === ms)) await new Promise<void>((r) => this.#heard.push(r));
  }
  /// The clock moved on by `ms`, every wait due by then done in turn.
  async advance(ms: number): Promise<void> {
    const end = this.now + ms;
    // (only the waits under way as it is moved on: one begun meanwhile, as a process the moment sets going is given its
    // time, counts from when it began, the clock already there)
    const before = new Set(this.sleepers.keys());
    for (;;) {
      const due = [...this.sleepers.entries()].filter(([id, s]) => before.has(id) && s.due <= end).sort((a, b) => a[1].due - b[1].due)[0];
      if (due === undefined) break;
      this.sleepers.delete(due[0]);
      this.now = Math.max(this.now, due[1].due);
      due[1].done();
      await turn();
    }
    this.now = Math.max(this.now, end);
  }
}

/// The TypeScript's time is the test's (its `wall`, and a part's Clock), while a case of it runs.
const realWall = { now: wall.now, after: wall.after, sleep: wall.sleep, within: wall.within };
function tsTime(t: TestTime) {
  wall.now = () => t.now;
  wall.after = (ms: number, f: () => void) => t.after(ms, f);
}
after(() => Object.assign(wall, realWall));
const effectClock = (t: TestTime): Clock.Clock => ({
  currentTimeMillisUnsafe: () => t.now,
  currentTimeMillis: Effect.sync(() => t.now),
  currentTimeNanosUnsafe: () => BigInt(t.now) * 1_000_000n,
  currentTimeNanos: Effect.sync(() => BigInt(t.now) * 1_000_000n),
  monotonicTimeNanosUnsafe: () => BigInt(t.now) * 1_000_000n,
  monotonicTimeNanos: Effect.sync(() => BigInt(t.now) * 1_000_000n),
  sleep: (d) => Effect.callback<void>((resume) => Effect.sync(t.after(Duration.toMillis(d), () => resume(Effect.void)))),
});

// ── the program ──

type Asked = (name: string, args: Json[]) => Promise<Json> | Json;
/// What the program's world answers, as the case running sets it.
let asked: Asked = (name) => {
  throw new Error(`nothing answers ${name}`);
};
let mbTime = new TestTime();
let program: { child: ChildProcessWithoutNullStreams; send: (c: Json) => Promise<Json> } | null = null;

function harness() {
  if (program !== null) return program;
  const shell = fresh("shell");
  const child = spawn(binary!, ["--builder", "harness-adb-devices", "--shell-dir", shell], { stdio: ["pipe", "pipe", "pipe"] });
  let seq = 0;
  const waiting = new Map<number, (answer: Json) => void>();
  let stderr = "";
  child.stderr.on("data", (d) => (stderr += d));
  const say = (m: Json) => void (child.stdin.writableEnded || child.stdin.write(`${JSON.stringify({ ...m, now: mbTime.now })}\n`));
  createInterface({ input: child.stdout }).on("line", (line) => {
    const m = JSON.parse(line);
    if (typeof m.ask === "number") {
      void (async () => {
        try {
          const result = await asked(m.name, m.args);
          say({ answer: m.ask, result: result === undefined ? null : result });
        } catch (e) {
          say({ answer: m.ask, threw: (e as Error).message, kind: (e as Json).kind ?? (e as Error).constructor?.name ?? "" });
        }
      })();
      return;
    }
    waiting.get(m.re)?.(m);
    waiting.delete(m.re);
  });
  child.on("exit", (code) => {
    for (const w of waiting.values()) w({ error: `the program ended (${code}): ${stderr}`, kind: "exit" });
  });
  program = {
    child,
    send: (c) =>
      new Promise((resolve) => {
        seq += 1;
        waiting.set(seq, resolve);
        say({ ...c, seq });
      }),
  };
  return program;
}
after(async () => {
  await childGone(program?.child);
  for (const dir of dirs) rmSync(dir, { recursive: true, force: true });
});

/// An outcome as both say it: `{ok}`, or what was thrown (its words).
function outcomeOf(m: Json): Json {
  if (m.kind === "exit") throw new Error(m.error);
  return "error" in m ? { error: m.error } : { ok: m.ok };
}
async function ts(f: () => unknown): Promise<Json> {
  try {
    return { ok: plain(await f()) };
  } catch (e) {
    return { error: (e as Error).message };
  }
}
const mbFn = async (name: string, ...args: Json[]) => outcomeOf(await harness().send({ op: "fn", name, args }));
const mbNew = async (spec: Json) => {
  const m = await harness().send({ op: "new", ...spec });
  if ("error" in m) throw new Error(`MoonBit: ${m.error}`);
};
const mbCall = async (id: string, name: string, ...args: Json[]) => outcomeOf(await harness().send({ op: "call", id, name, args }));
/// A function the program gave in an argument, called.
const mbCb = async (cb: Json, ...args: Json[]) => {
  const m = await harness().send({ op: "cb", id: cb.$cb, args });
  if ("error" in m) throw Object.assign(new Error(m.error), { kind: m.kind });
  return m.ok;
};
let worded = false;
async function words(lang: "zh" | "en" = "zh") {
  if (!worded) {
    await harness().send({ op: "words", zh: zhStation, en: enStation });
    worded = true;
  }
  setStationLang(lang);
  await harness().send({ op: "lang", lang });
}
let parts = 0;
const partId = (what: string) => `${what}${++parts}`;

/// Both sides of a case the same: each given a world of its own (`make`), what each comes to compared.
async function same(what: string, make: (side: "ts" | "mb") => Promise<Json>) {
  const a = await make("ts");
  const b = await make("mb");
  assert.deepEqual(b, a, `${what}: ${firstDiffer(b, a)}`);
  return a;
}

/// Where `b` first differs from `a` (its path and both values, as JSON): an assertion's own words leave nested arrays
/// as [Array], which says nothing of a case that failed once on CI.
function firstDiffer(b: Json, a: Json, at = "$"): string {
  if (JSON.stringify(a) === JSON.stringify(b)) return "the same";
  if (a !== null && b !== null && typeof a === "object" && typeof b === "object" && Array.isArray(a) === Array.isArray(b)) {
    const keys = Array.isArray(a) ? [...Array(Math.max(a.length, (b as Json[]).length)).keys()] : [...new Set([...Object.keys(a), ...Object.keys(b)])];
    for (const k of keys) {
      const x = (a as any)[k], y = (b as any)[k];
      if (JSON.stringify(x) !== JSON.stringify(y)) return firstDiffer(y, x, `${at}[${JSON.stringify(k)}]`);
    }
  }
  return `at ${at}: program ${JSON.stringify(b)?.slice(0, 2000)}, TypeScript ${JSON.stringify(a)?.slice(0, 2000)}`;
}

// ── what needs no world ──

/// adb packets: its command, an argument, a payload, as adb writes them.
function packet(command: number, id: number, payload: Buffer, bad = false): Buffer {
  const head = Buffer.alloc(24);
  head.writeUInt32LE(command, 0);
  head.writeUInt32LE(id, 4);
  head.writeUInt32LE(payload.length, 12);
  head.writeUInt32LE(bad ? 7 : ~command >>> 0, 20);
  return Buffer.concat([head, payload]);
}
const OPEN = 0x4e45504f, WRTE = 0x45545257, OKAY = 0x59414b4f, CLSE = 0x45534c43, STLS = 0x534c5453, CNXN = 0x4e584e43;

/// A seeded random: the same cases every run.
function rng(seed: number) {
  let s = seed >>> 0;
  return () => {
    s = (s * 1664525 + 1013904223) >>> 0;
    return s / 2 ** 32;
  };
}

test("what adb's frames make of use, split anywhere, as the TypeScript reads them", async () => {
  const services = [
    "shell:ls /sdcard\0", "shell,v2,raw:getprop\0", `shell:${KEEP_LENDING} pm grant fail.still android.permission.WRITE_SECURE_SETTINGS\0`,
    `shell:${KEEP_LENDING} cmd deviceidle whitelist +fail.still\0`, `shell:${KEEP_LENDING} sh -c 'cat /proc/sys/kernel/random/boot_id; getprop service.adb.tcp.port'\0`,
    "tcpip:5555", `shell,v2:${DISPLAY_MARK} wm size\0\0`, "localabstract:scrcpy_0a1b2c3d\0", "localabstract:scrcpy_0A1B2C3D", `shell:${DISPLAY_MARK}\nls`,
    "sync:", "shell:", "", "exec:screencap -p\0", "shell:é ü 手机\0", "shell,x:y\0",
  ];
  const r = rng(7);
  for (let c = 0; c < 60; c++) {
    const frames: Buffer[] = [];
    const n = 1 + Math.floor(r() * 8);
    for (let i = 0; i < n; i++) {
      const id = 1 + Math.floor(r() * 4);
      const pick = r();
      if (pick < 0.4) frames.push(packet(OPEN, id, Buffer.from(services[Math.floor(r() * services.length)]!)));
      else if (pick < 0.55) frames.push(packet(WRTE, id, randomBytesSeeded(r, Math.floor(r() * 40))));
      else if (pick < 0.65) frames.push(packet(OKAY, id, Buffer.alloc(0)));
      else if (pick < 0.75) frames.push(packet(CLSE, id, Buffer.alloc(0)));
      else if (pick < 0.8) frames.push(packet(CNXN, 0, Buffer.from("host::\0")));
      else if (pick < 0.83) frames.push(packet(STLS, 0, Buffer.alloc(0)));
      else if (pick < 0.86) frames.push(packet(WRTE, id, Buffer.from("x"), true));
      else frames.push(packet(OPEN, id, Buffer.alloc(9000, 0x61)));
    }
    const all = Buffer.concat(frames);
    const chunks: Buffer[] = [];
    for (let at = 0; at < all.length; ) {
      const size = 1 + Math.floor(r() * 50);
      chunks.push(all.subarray(at, at + size));
      at += size;
    }
    const pkg = r() < 0.7 ? "fail.still" : "";
    const heard: boolean[] = [];
    const a = new AdbActivity(pkg, (force) => heard.push(force));
    for (const chunk of chunks) a.take(chunk);
    assert.deepEqual(await mbFn("activity", pkg, chunks.map((b) => b.toString("base64"))), { ok: heard }, `case ${c}`);
  }
});

function randomBytesSeeded(r: () => number, n: number): Buffer {
  return Buffer.from(Array.from({ length: n }, () => Math.floor(r() * 256)));
}

test("the functions of no world: what each says to the same inputs", async () => {
  await words("zh");
  const cases: [string, Json[], () => unknown][] = [];
  const add = (name: string, args: Json[], f: () => unknown) => cases.push([name, args, f]);
  for (const m of ["no", "", "手机 is granted to another chat", "x".repeat(70000), "é".repeat(40000)]) add("failure", [m], () => failure(m));
  for (const said of ["[server] INFO: New display: 1080x2400/420 (id=2)\n", "New display: 1x/2 (id=3)", "New display: 1x2/3 (id=4) New display: 5x6/7 (id=8)", "", "New display: 10x20/30 (id=)New display: 1x2/3 (id=9)"])
    add("displayOf", [said], () => displayOf(said));
  for (const wm of ["Physical density: 420\n", "Physical density: 420\nOverride density: 360\n", "", "Override density: x Physical density: 1"]) add("densityOf", [wm], () => densityOf(wm));
  for (const wm of ["Physical size: 1080x2400", "Physical size: 1080x2400\nOverride size: 720x1600", "", "Physical size: 1x"]) add("sizeOf", [wm], () => sizeOf(wm));
  const list = ["RootTask id=7723 bounds=[0,0][1140,2616] displayId=13 userId=0", " configuration={1.0 ?? displayId=13}", "Stack id=12 displayId=13 x displayId=2", "RootTask id=7a displayId=13", "RootTask id=5\rStack id=6 displayId=13", "RootTask id=7720 bounds displayId=0 userId=0"].join("\n");
  for (const id of [13, 0, 2, 4]) add("rootTasksOn", [list, id], () => rootTasksOn(list, id));
  for (const [a, b, c] of [["a", "b", "c"], ["", "", ""], ["\x07x\ny", "é".repeat(30), "  "]] as const) add("text", [a, 5], () => text(a, 5));
  add("text", [7, 3], () => text(7, 3));
  for (const p of ["fail.still", "a b", "", "x".repeat(201), "A_1.b", "a;b"]) add("isPackage", [p], () => isPackage(p));
  for (const h of [{}, { "stillfail-lang": "en" }, { "StillFail-Lang": "zh-CN" }, { "stillfail-lang": "" }, { other: "en" }]) add("langOfCore", [h], () => langOfCore(h as any));
  for (const t of ["[::1]:5555", "cam.local:554", "nohost", "a:b:c", "[x]:1", ":"]) add("hostPort", [t], () => hostPort(t));
  for (const p of ["chat", "hour", "idle", "eight", undefined, "other"]) add("scopeSaid", [p ?? null], () => scopeSaid(p as any));
  const phones = [{ serial: "127.0.0.1:37001", device: "Pixel 9", android: "16", owner: { name: "Pat", email: "pat@example.com" }, adb: "connected", message: "" }];
  add("listed", [[]], () => listed([]));
  add("listed", [phones], () => listed(phones));
  const display = { id: 12, surface: "11529215049899194809", width: 1080, height: 2400, density: 420 };
  for (const [s, port, gone, d] of [
    [[], null, null, null], [phones, 5040, null, null], [[], 5040, { at: T0, ended: "stopped" }, null], [phones, null, { at: T0 + 1, ended: "closed" }, null],
    [phones, 5040, null, display], [phones, 5040, null, { failed: "scrcpy ended" }], [[{ serial: "s", adb: "unpaired", device: "" }], 1, null, null],
  ] as const) add("reached", [s, port, gone, d], () => reached(s as any, port, gone as any, d as any));
  add("displayed", [display], () => displayed(display));
  add("displayed", [{ failed: "no" }], () => displayed({ failed: "no" }));
  const reqs: Json[] = [];
  for (const status of ["pending", "granted", "denied", "ended"])
    for (const link of [undefined, "connected", "unpaired", "gone", "off"])
      for (const why of [undefined, "", "已收回"])
        reqs.push({ id: "p1", session: "s", chat: "CHAT/1", owner: "pat@example.com", reason: "r", at: 1, status, ...(link ? { link } : {}), ...(why !== undefined ? { why } : {}), scope: "hour" });
  for (const r of reqs) {
    add("said", [r], () => said(r));
    add("linkSaid", [r], () => linkSaid(r));
  }
  for (const d of [
    { id: "0123456789abcdef", name: "cam", kind: "tcp", target: "192.168.1.20:554" }, { id: "0123456789abcdef", name: "cam", kind: "tcp", target: "[fe80::1]:80" },
    { id: "0123456789abcdef", name: "cam", kind: "tcp", target: "nohost" }, { id: "0123456789abcdef", name: "cam", kind: "tcp", target: "h:99999" },
    { id: "0123456789abcdef", name: "cam", kind: "tcp", target: "h:0" }, { id: "0123456789abcdef", name: "cam", kind: "tcp", target: "h_x:1" },
    { id: "0123456789abcdef", name: " ", kind: "adb", target: "x" }, { id: "0123456789ABCDEF", name: "x", kind: "adb", target: "x" },
    { id: "0123456789abcdef", name: "x", kind: "usb", target: "x" }, { id: "0123456789abcdef", name: "x", kind: "serial", target: "ttyUSB0" },
    { id: "0123456789abcdef", name: "x", kind: "serial", target: "COM3" }, { id: "0123456789abcdef", name: "x", kind: "serial", target: "/dev/tty", baud: 7 },
    { id: "0123456789abcdef", name: "x", kind: "serial", target: "/dev/tty", baud: 9600 }, { id: "0123456789abcdef", name: "x", kind: "serial", target: "/dev/tty", baud: 9600.5 },
    { id: "0123456789abcdef", name: "x", kind: "adb", target: "a b" }, { id: "0123456789abcdef", name: "x", kind: "adb", target: "a\0b" }, null, [],
    { id: "0123456789abcdef", name: "x".repeat(81), kind: "adb", target: "x" }, { id: "0123456789abcdef", name: "x", kind: "adb", target: "x".repeat(257) },
  ]) add("deviceRefusal", [d], () => deviceRefusal(d));
  for (const e of [{ name: "pixel", kind: "adb", target: "R5CT1234" }, { name: "cam", kind: "tcp", target: "10.0.0.1:554" }, { name: "board", kind: "serial", target: "/dev/ttyUSB0", baud: 9600 }, { name: "b", kind: "serial", target: "/dev/x" }])
    add("reachedAt", [e, 4000], () => reachedAt(e as any, 4000));
  for (const ms of [0, T0, 951782400000, 1, -1000, 4102444800999]) add("isoTime", [ms], () => new Date(ms).toISOString());
  for (const [t, first, chan] of [
    [{ surface: "slack", channel: "C1" }, "  <@U1> hi\n there", null], [{ surface: "ember" }, "x", null], [{ surface: "slack", channel: "D1" }, null, null],
    [{ surface: "slack", channel: "C1", title: " Named " }, "x", null], [{ surface: "feishu:x", channel: "oc_1" }, "", "Group"], [{ surface: "slack", channel: "C1" }, "\n\n", " general "],
    [{ autoTitle: "Auto" }, null, null], [{ surface: "chat" }, null, null], [{}, "<@U12x> a", null],
  ] as const) add("chatTitle", [t, first, chan, "新对话", "私信"], () => chatTitle(t as any, first, chan, { untitled: "新对话", directMessage: "私信" }));
  add("decls", [], () => [ADB_DEVICES, PHONE_USE, PHONE_SEND, DEVICE_LIST, DEVICE_USE]);
  // device_list's answer, through the TypeScript's tool.
  for (const all of [[], [{ id: "a", name: "cam" }]]) {
    const tool = deviceTools({ list: async () => all as any, use: async () => "", done: async () => "" })[0]!;
    add("deviceListSaid", [all], () => tool.run("s", {}, undefined as any));
  }
  for (const [mail, serial] of [["Pat@Example.com", "127.0.0.1:37001"], ["", ""]]) add("phoneId", [mail, serial], () => createHash("sha256").update(`${mail.toLowerCase()}\0${serial}`).digest("hex").slice(0, 16));
  for (const [name, args, f] of cases) assert.deepEqual(await mbFn(name, ...args), await ts(f), `${name}(${JSON.stringify(args).slice(0, 200)})`);
});

test("screencap's id of a display, as SurfaceFlinger's lines say it", async () => {
  const DISPLAYS = [
    `    mBaseDisplayInfo=DisplayInfo{"Built-in Screen", displayId 0, displayGroupId 0, FLAG_SECURE, real 1080 x 2400, type INTERNAL, uniqueId "local:4619827259835644672", app 1080 x 2400}`,
    `    mBaseDisplayInfo=DisplayInfo{"scrcpy", displayId 2, displayGroupId 1, FLAG_PRESENTATION, real 1080 x 2400, type VIRTUAL, uniqueId "virtual:com.android.shell,2000,scrcpy,1", owner com.android.shell (uid 2000)}`,
    `    mBaseDisplayInfo=DisplayInfo{"scrcpy", displayId 12, displayGroupId 2, FLAG_PRESENTATION, real 1080 x 2400, type VIRTUAL, uniqueId "virtual:com.android.shell,2000,scrcpy,0", layerStack 12, owner com.android.shell (uid 2000)}`,
    `    mBaseDisplayInfo=DisplayInfo{"x", xdisplayId 3, uniqueId "", layerStack 3}`,
  ].join("\n");
  const FLINGER = [
    `Display 4619827259835644672 (HWC display 0): port=0 pnpId=GGL displayName="EMU_display_0"`,
    `Display 11529215046400789845 (Virtual display): displayName="scrcpy" uniqueId="virtual:com.android.shell,2000,scrcpy,0"`,
    `Display 11529215049899194809 (Virtual display): displayName="scrcpy" uniqueId="virtual:com.android.shell,2000,scrcpy,1"`,
  ].join("\n");
  const noIds = `Display 11529215049903610350 (Virtual display): displayName="scrcpy"`;
  const dump = ["Display 4630946165954792596 (physical, \"内屏\")", "   layerFilter={layerStack=0, toInternalDisplay=false}", "Display 11529215049903610350 (virtual, \"scrcpy\")", "   layerFilter={layerStack=12, toInternalDisplay=false}", "Display 9 (virtualx)", "  layerFilter={layerStack=3}", "x", "  layerFilter={layerStack=12}"].join("\n");
  for (const [displays, ids, id] of [[DISPLAYS, FLINGER, 2], [DISPLAYS, FLINGER, 12], [DISPLAYS, FLINGER.split("\n")[0]!, 2], [DISPLAYS, FLINGER, 3], [DISPLAYS, noIds, 12], [DISPLAYS, noIds, 3], [DISPLAYS, `${noIds}\nuniqueId=`, 12], [DISPLAYS, "", 12]] as const) {
    let flingers = 0;
    const want = await ts(() => surfaceOf(displays, ids, id, async () => (flingers++, dump)));
    let mbFlingers = 0;
    asked = (name) => {
      assert.equal(name, "flinger");
      mbFlingers++;
      return dump;
    };
    assert.deepEqual(await mbFn("surfaceOf", displays, ids, id), want, `${id} of ${ids.slice(0, 40)}`);
    assert.equal(mbFlingers, flingers);
  }
});

test("a phone's key and usual port agree across both implementations", async () => {
  for (const device of ["u1/" + "ab".repeat(32), "pat/" + "cd".repeat(32), "x12345678"]) {
    assert.deepEqual(await mbFn("usualPort", device), { ok: usualPort(device) });
  }
  const conn = { remoteId: () => "cd".repeat(32) } as any;
  asked = (name) => (name === "conn.remoteId" ? "cd".repeat(32) : null);
  for (const ask of [{ phone: "ab".repeat(32) }, { phone: "xy" }, {}, { phone: "AB".repeat(32) }])
    assert.deepEqual(await mbFn("key", { sub: "u1" }, "conn", ask), await ts(() => key({ sub: "u1" } as any, conn, ask)));
});

// ── a chat's grants, on twin databases ──

/// A world for the grants: its sessions, chats, cards and what it was told, kept the same way for either side.
function grantsWorld(file: string) {
  let db = new DatabaseSync(file);
  db.exec("CREATE TABLE IF NOT EXISTS thread_sessions(thread INTEGER NOT NULL,session TEXT NOT NULL,joined_at INTEGER NOT NULL,PRIMARY KEY(thread,session)); INSERT INTO thread_sessions VALUES(1,'s1',1),(1,'s4',2),(2,'s2',1),(1,'s5',3)");
  const log: Json[] = [];
  const cards: { ts: string; card: Json }[] = [];
  const titles = new Map<string, string | null>([["s1", "First chat"], ["s2", "Second chat"], ["s3", "Home chat"], ["s4", null]]);
  const sessions = new Map<string, { archivedAt?: number | null; ws: string | null; workspace: string }>([
    ["s1", { ws: "work-a", workspace: "/chat/s1" }], ["s2", { ws: "work-b", workspace: "/chat/s2" }], ["s3", { ws: null, workspace: "/chat/s3" }],
    ["s4", { ws: "work-a", workspace: "/chat/s4" }], ["s5", { ws: "work-a", workspace: "/chat/s5" }],
  ]);
  const surfaces = new Map<string, string>([["s1", STILLFAIL_SURFACE], ["s2", "slack"], ["s3", STILLFAIL_SURFACE], ["s4", STILLFAIL_SURFACE], ["s5", STILLFAIL_SURFACE]]);
  let n = 0;
  let hidden = false;
  let hasChats = true;
  let originalJoined = true;
  let busy = 0;
  let ids = 0;
  const subs: ((c: Json) => void)[] = [];
  const thread = (s: string) => ({ connect: "c", thread: { id: s === "s2" ? 2 : 1, channel: s === "s2" ? "C2" : "CHAT", threadTs: "1.0", surface: surfaces.get(s) } });
  const store = {
    getSession: (k: string) => sessions.get(k) ?? null,
    starter: (s: string) => (s === "s4" ? "Kim@Example.com" : "pat@example.com"),
    latestThread: (s: string) => (log.push(["latestThread", s]), hasChats ? thread(s) : null),
    sessionThreadById: (s: string) => (originalJoined ? thread(s) : null),
    insertMessage: (m: Json, before?: () => void) => {
      written(m, before === undefined ? undefined : () => before());
      return [n];
    },
    pendingCardHeader: (): [{ ts: string }, unknown] | null => (hidden || cards.length === 0 ? null : [{ ts: cards.at(-1)!.ts }, cards.at(-1)!.card]),
    withdrawCard: (_a: string, t: number, ts: string) => (log.push(["withdraw", t, ts]), true),
    restateCard: (_a: string, t: number, ts: string, f: (was: Json) => Json) => {
      const c = cards.find((x) => x.ts === ts);
      if (c !== undefined) c.card = f(c.card);
      log.push(["restate", t, ts, plain(c?.card ?? null)]);
      return true;
    },
    threadSessions: (t: number) => (t === 1 ? [{ session: "s1" }] : []),
    subscribe: (f: (c: Json) => void) => void subs.push(f),
  };
  /// A message written: a busy writer refuses it first, the check inside the write runs, then it is kept.
  function busyFirst() {
    if (busy > 0) {
      busy--;
      throw new MessageWriteBusy("busy");
    }
  }
  function written(m: Json, before?: () => void) {
    busyFirst();
    before?.();
    keep(m);
  }
  function keep(m: Json) {
    log.push(["insert", plain(m)]);
    cards.push({ ts: m.ts, card: m.card });
    hidden = false;
    n++;
  }
  /// The same, its check the program's, called back.
  async function writtenAsync(m: Json, before?: () => Promise<unknown>) {
    busyFirst();
    if (before) await before();
    keep(m);
    return [n];
  }
  return {
    file, log, cards, titles, sessions, store, subs, writtenAsync,
    hide: () => void (hidden = true), show: () => void (hidden = false),
    withoutOriginal: () => void (originalJoined = false), withoutChats: () => void (hasChats = false),
    busy: (k: number) => void (busy = k),
    title: (r: Json) => (titles.has(r.session) ? titles.get(r.session)! : null),
    nextId: () => `p${++ids}`,
    post: (connect: string, where: Json, text: string) => (log.push(["post", connect, where, text]), `t${n + 1}`),
    get db() { return db; }, set db(d) { db = d; },
    rows: () => db.prepare("SELECT id,session,owner,status,body FROM adb_requests ORDER BY rowid").all().map((r) => ({ ...r })),
  };
}

/// What a step of grants is: its name and its arguments.
type Step = [string, ...Json[]];

/// The grants of either side, made on a world of `grantsWorld`, and each step run on it: what it answered, then the
/// world's log, the cards and the rows.
async function grantsRun(side: "ts" | "mb", steps: Step[], outcomes = false) {
  const t = new TestTime();
  t.auto = true;
  const w = grantsWorld(join(fresh(`grants-${side}`), "db"));
  const told: Json[] = [];
  const notified: Json[] = [];
  const saved: Json[] = [];
  const hub = {
    store: w.store,
    chat: (connect: string) => ({ post: async (where: Json, text: string) => w.post(connect, where, text) }),
    shared: (thread: number, n: number, session: string, text: string) => w.log.push(["shared", thread, n, session, text]),
    notify: (s: string, text: string) => {
      if (s === "gone") throw new Error("no such session");
      notified.push([s, text]);
    },
    prepareCardPosts: async (threads: number[]) => void w.log.push(["prepareCardPosts", threads]),
  };
  const cardOutcomes = outcomes ? { save: (item: Json, save: () => void) => (saved.push(plain(item)), save(), "1") } : undefined;
  const answers: Json[] = [];
  let grants: PhoneGrants | null = null;
  const id = partId("grants");
  if (side === "ts") {
    tsTime(t);
    grants = new PhoneGrants({
      db: w.db, hub: hub as any, cardOutcomes, home: () => "home", title: (r) => w.title(r), now: () => t.now,
      told: (r, workspace, change) => told.push([plain(r), workspace, change]), id: () => w.nextId(),
    });
  } else {
    mbTime = t;
    w.db.close();
    asked = async (name, args) => {
      switch (name) {
        case "grants.title": return w.title(args[0]);
        case "grants.told": return void told.push(args);
        case "grants.home": return "home";
        case "grants.id": return w.nextId();
        case "store.has": return false;
        case "hub.has": return args[0] === "prepareCardPosts";
        case "hub.identity": return null;
        case "hub.shared": return void hub.shared(args[0], args[1], args[2], args[3]);
        case "hub.notify": return hub.notify(args[0], args[1]);
        case "hub.prepareCardPosts": return hub.prepareCardPosts(args[0]);
        case "chat.post": return w.post(args[0], args[1], args[2]);
        case "cardOutcomes.save": return void (saved.push(args[0]), await mbCb(args[1]));
        case "clock.sleep": return new Promise((r) => t.after(args[0], r, args[1]));
        case "clock.cancel": return void t.cancel(args[0]);
        case "store.insertMessage":
          // (the check run inside the write, as the store runs it)
          return w.writtenAsync(args[0], args[1] ? async () => mbCb(args[1]) : undefined);
        case "store.restateCard": {
          const was = w.cards.find((x) => x.ts === args[2])?.card;
          const made = await mbCb(args[3], was ?? null);
          return w.store.restateCard(args[0], args[1], args[2], () => made);
        }
        default:
          if (name.startsWith("store.")) return (w.store as Json)[name.slice(6)](...args);
          throw new Error(`grants: nothing answers ${name}`);
      }
    };
    await mbNew({ kind: "grants", id, db: w.file, outcomes });
  }
  const tool = side === "ts" ? phoneTools(grants!, async (owner, grant) => `reach ${owner} ${grant}`)[0]! : null;
  if (side === "mb") {
    const before = asked;
    asked = (name, args) => (name === "phone.reach" ? `reach ${args[0]} ${args[1]}` : before(name, args));
  }
  for (const [step, ...args] of steps) {
    let out: Json;
    if (step === "pass") {
      t.now += args[0];
      out = null;
    } else if (step === "world") {
      (w as Json)[args[0]](...args.slice(1));
      out = null;
    } else if (step === "archive" || step === "remove" || step === "rename") {
      const [s] = args;
      let change: Json;
      if (step === "archive") {
        w.sessions.set(s, { ...w.sessions.get(s)!, archivedAt: t.now });
        change = { type: "session", key: s };
      } else if (step === "remove") {
        const ws = w.sessions.get(s)!.ws;
        w.sessions.delete(s);
        change = { type: "sessionRemoved", key: s, ws };
      } else {
        w.titles.set(s, args[1]);
        change = { type: "thread", id: args[2] ?? 1 };
      }
      out = side === "ts" ? await ts(() => w.subs[0]!(change)) : await mbCall(id, "changed", change);
    } else if (side === "ts") {
      const g = grants! as Json;
      out = await ts(() => (step === "phoneUse" ? tool!.run(args[0], args[1], undefined as any) : step === "shown" ? g.shown(g.get(args[0])) : step === "cardPending" ? g.cardPending(g.get(args[0])) : step === "ask" ? g.ask(args[0], args[1], args[2], undefined, args[3]) : g[step](...args)));
    } else {
      out = step === "shown" ? await mbCall(id, "shown", (await mbCall(id, "get", args[0])).ok)
        : step === "cardPending" ? await mbCall(id, "cardPending", (await mbCall(id, "get", args[0])).ok)
        : await mbCall(id, step, ...args.map((a) => (a === undefined ? null : a)));
    }
    answers.push([step, out]);
  }
  if (side === "mb") w.db = new DatabaseSync(w.file);
  const rows = w.rows();
  w.db.close();
  if (side === "ts") Object.assign(wall, realWall);
  return { answers, told, notified, saved, log: w.log, cards: w.cards, rows };
}

test("a chat's phone grants asked, decided, used, linked and ended, the same on twin databases", async () => {
  await words("zh");
  const scenarios: [string, Step[], boolean?][] = [
    ["asked and granted for an hour, then run out", [
      ["ask", "s1", "debug the screen", false], ["ask", "s1", "again", false], ["get", "p1"], ["decide", "pat@example.com", "p1", "hour", "work-a"],
      ["held", "s1"], ["ofOwner", "PAT@example.com", "work-a"], ["shown", "p1"], ["pass", 3600_000], ["held", "s1"], ["get", "p1"],
    ]],
    ["refused, signed, taken back, decided twice and by another", [
      ["ask", "s1", "one", false], ["decide", "kim@example.com", "p1", null, "work-a"], ["decide", "pat@example.com", "p1", "forever", "work-a"],
      ["decide", "pat@example.com", "p1", null, "work-b"], ["decide", "pat@example.com", "p1", null, "work-a"], ["decide", "pat@example.com", "p1", "hour", "work-a"],
      ["ask", "s1", "two", false], ["decide", "Pat@Example.com", "p2", "chat", "work-a", { body: { v: 1, request: "p2" }, sig: { key: "k", sig: "s" } }],
      ["sign", "pat@example.com", "p2", { body: { v: 2 }, sig: "x", extra: 1 }, "work-a"], ["sign", "pat@example.com", "p2", "no", "work-a"],
      ["sign", "pat@example.com", "p1", {}, "work-a"], ["revoke", "kim@example.com", "p2", "work-a"], ["revoke", "pat@example.com", "p2", "work-a"],
      ["revoke", "pat@example.com", "p2", "work-a"], ["get", "p2"],
    ]],
    ["an idle grant used, idle and ended; used announced at most once a second", [
      ["ask", "s1", "idle", false], ["decide", "pat@example.com", "p1", "idle", "work-a"], ["used", "p1", false], ["pass", 500], ["used", "p1", false],
      ["used", "p1", true], ["pass", 1000], ["used", "p1", false], ["pass", 3599_000], ["held", "s1"], ["pass", 2000], ["held", "s1"], ["used", "p1", true],
    ]],
    ["linked as the phone is held, its card restated and its agent told", [
      ["ask", "s1", "link", false], ["decide", "pat@example.com", "p1", "eight", "work-a"], ["ask", "s4", "kim's chat asks pat's phone", false, "PAT@example.com"],
      ["decide", "pat@example.com", "p2", "chat", "work-a"], ["linked", "pat@example.com", { adb: "connecting" }], ["linked", "pat@example.com", { adb: "unpaired" }],
      ["linked", "pat@example.com", { adb: "unpaired" }], ["linked", "Pat@example.com", { adb: "connected" }], ["linked", "pat@example.com", null],
      ["linked", "pat@example.com", { adb: "connected" }], ["get", "p1"], ["grantedOfOwner", "pat@example.com"], ["live"], ["phoneUse", "s1", { reason: "x" }],
    ]],
    ["handed back, archived, removed and renamed", [
      ["ask", "s1", "a", false], ["ask", "s2", "b", false], ["ask", "s3", "c", false], ["decide", "pat@example.com", "p1", "chat", "work-a"],
      ["ofOwner", "pat@example.com"], ["rename", "s1", "Renamed", 1], ["rename", "s2", "Second again", 2], ["rename", "s1", "Renamed", 1],
      ["release", "s2", "kim@example.com"], ["release", "s2"], ["release", "s2"], ["archive", "s3"], ["get", "p3"], ["remove", "s1"], ["get", "p1"], ["ofOwner", "pat@example.com", "home"],
      ["starter", "s4"],
    ]],
    ["phone_use: asked, waiting, granted, handed back; a card no longer pending, asked again", [
      ["phoneUse", "s1", { reason: "" }], ["phoneUse", "s1", { reason: "debug" }], ["phoneUse", "s1", { reason: "debug" }], ["world", "hide"],
      ["phoneUse", "s1", { reason: "debug" }], ["cardPending", "p1"], ["phoneUse", "s1", { reason: "debug", reask: true }], ["phoneUse", "s1", { reason: "debug" }],
      ["decide", "pat@example.com", "p1", "idle", "work-a"], ["phoneUse", "s1", {}], ["phoneUse", "s1", { done: true }], ["phoneUse", "s1", { done: true }],
      ["phoneUse", "s2", { reason: "slack" }], ["world", "withoutOriginal"], ["ask", "s2", "x", true], ["world", "withoutChats"], ["ask", "s5", "x", false],
    ]],
    ["a busy writer waited out, and the outbox keeping the cards' outcomes", [
      ["world", "busy", 2], ["ask", "s1", "busy", false], ["decide", "pat@example.com", "p1", "hour", "work-a"], ["linked", "pat@example.com", { adb: "connected" }],
      ["revoke", "pat@example.com", "p1", "work-a"],
    ], true],
  ];
  for (const [what, steps, outcomes] of scenarios) await same(what, (side) => grantsRun(side, steps, outcomes));
});

test("a grant named by its chat, whichever chat of the session it is and whatever it is called", async () => {
  for (const lang of ["zh", "en"] as const) {
    await words(lang);
    const threads: Record<string, Json> = {
      "CHAT/1.0": { id: 1, surface: STILLFAIL_SURFACE, channel: "CHAT", title: "" },
      "C1/2.0": { id: 2, surface: "slack", channel: "C1" },
      "C1/3.0": { id: 3, surface: "slack", channel: "C1", title: "Given" },
      "D1/4.0": { id: 4, surface: "slack", channel: "D1" },
      "S/5.0": { id: 5, surface: "stillfail", channel: "S" },
    };
    const first: Record<number, string | null> = { 1: "said first", 2: "  <@U1> look at\nthis", 3: "x", 4: null, 5: "y" };
    const latest: Record<string, Json> = { s1: { thread: threads["C1/2.0"], firstText: first[2] }, s2: { thread: threads["D1/4.0"], firstText: null }, s3: null };
    const store = {
      sessionThread: (_s: string, channel: string, ts: string) => {
        const t = threads[`${channel}/${ts}`];
        return t === undefined ? null : { thread: t };
      },
      firstText: (id: number) => first[id] ?? null,
      sessionChat: (s: string) => latest[s] ?? null,
    };
    asked = (name, args) => {
      const [, method] = name.split(".");
      return (store as Json)[method!](...args);
    };
    for (const session of ["s1", "s2", "s3"])
      for (const chat of [...Object.keys(threads), "nowhere", "X/9.0"])
        assert.deepEqual(await mbFn("grantChatTitle", { session, chat }), await ts(() => grantChatTitle(store as any, { session, chat } as any)), `${lang} ${session} ${chat}`);
  }
  await words("zh");
});

test("the door's gate: the grant's session, its jobs, the station's own adb, or its own directory", async () => {
  const root = realpathSync(fresh("gate"));
  mkdirSync(join(root, "a", "deep"), { recursive: true });
  const row = (pid: number, ppid: number, pgid = pid) => ({ pid, ppid, pgid, bytes: 0, command: "adb" });
  const STATION = 100;
  const table = [row(1, 1), row(STATION, 1), row(101, STATION), row(200, 1), row(201, 200), row(202, 201), row(203, 202), row(300, 1), row(301, 300), row(400, 1), row(401, 400, 400), row(500, STATION, 500), row(600, 600)];
  const worlds: [string, Partial<GateDeps>, string?][] = [
    ["as it is", {}],
    ["no session", { session: () => null }],
    ["no table", { table: async () => null }],
    ["a workspace of /", { session: () => ({ workspace: "/" }) }],
    ["none", { session: () => ({ workspace: null }) }],
    ["its own directory", { session: () => ({ workspace: join(root, "a") }), cwds: async (pids) => new Map(pids.map((p) => [p, p === 600 ? join(root, "a", "deep") : p === 301 ? join(root, "ab") : "/x"])) }, "a device's words"],
    ["a link to it", { session: () => ({ workspace: join(root, "a", "..", "a") + "/" }), cwds: async (pids) => new Map(pids.map((p) => [p, join(root, "a")])) }],
  ];
  for (const [what, over, elsewhere] of worlds) {
    const deps: GateDeps = {
      session: () => ({ workspace: "/chats/a" }), table: async () => table, runners: () => [200, 201],
      jobs: () => [{ pgid: 400, mine: () => true }, { pgid: 500, mine: () => false }], cwds: async () => new Map(), self: STATION,
      ...(elsewhere ? { elsewhere } : {}), ...over,
    };
    for (const holders of [[203], [401], [101], [301], [500], [999], [], [600], [301, 203], [600, 301]]) {
      const want = await ts(() => gate(deps, "g", holders));
      const jobs = deps.jobs();
      asked = async (name, args) => {
        switch (name) {
          case "gate.session": return deps.session(args[0]);
          case "gate.table": return deps.table();
          case "gate.runners": return deps.runners(args[0]);
          case "gate.jobs": return jobs.map((j) => ({ pgid: j.pgid }));
          case "gate.mine": return jobs[args[0]]!.mine(args[1]);
          case "gate.cwds": return [...(await deps.cwds(args[0])).entries()];
          case "fs.realpath": return realpath(args[0]);
          default: throw new Error(`gate: ${name}`);
        }
      };
      assert.deepEqual(await mbFn("gate", "g", holders, STATION, elsewhere ?? null), want, `${what}: ${holders}`);
    }
  }
});

test("devices kept by their station: added, refused, listed in their order, taken off", async () => {
  const PAT = { sub: "pat", email: "Pat@Example.com", name: "Pat" };
  const given: Json[] = [
    { name: "cam", kind: "tcp", target: "192.168.1.20:554" }, { name: "CAM", kind: "tcp", target: "10.0.0.1:80" }, { name: "x", kind: "tcp", target: "nohost" },
    { name: "x", kind: "usb", target: "a" }, { name: "x", target: "a" }, { name: "x", kind: "serial", target: "ttyUSB0" }, { name: "x", kind: "serial", target: "/dev/ttyUSB0", baud: 7 },
    { name: " board ", kind: "serial", target: " /dev/ttyUSB0 ", baud: "9600" }, { name: "pixel", kind: "adb", target: "R5CT1234", baud: "" }, { name: "n", kind: "adb", target: "t", baud: null },
    { name: "b2", kind: "serial", target: "COM4", baud: true }, { name: 5, kind: "adb", target: "x" }, { name: "b3", kind: "serial", target: "COM5", baud: [9600] },
  ];
  const ids: string[] = [];
  const run = async (side: "ts" | "mb") => {
    const file = join(fresh(`registry-${side}`), "db");
    const out: Json[] = [];
    if (side === "ts") {
      const db = new DatabaseSync(file);
      const r = new DeviceRegistry(db);
      for (const [i, g] of given.entries()) {
        const made = r.add(i % 2 === 0 ? "ws" : "other", PAT, g, 100 + i);
        // (an id is made for every one, refused or not: a refused one's is any)
        ids.push(typeof made === "string" ? "0000000000000000" : made.id);
        out.push(typeof made === "string" ? { refused: made } : { ok: made });
      }
      out.push(r.of("ws"), r.of("other"), r.get("ws", ids[0]!), r.get("other", ids[0]!), r.remove("ws", ids[0]!), r.remove("ws", ids[0]!), r.of("ws"));
      ids.splice(given.length);
      db.close();
    } else {
      const left = [...ids];
      asked = (name) => {
        assert.equal(name, "random.hex");
        return left.shift();
      };
      const id = partId("registry");
      await mbNew({ kind: "registry", id, db: file });
      for (const [i, g] of given.entries()) out.push((await mbCall(id, "add", i % 2 === 0 ? "ws" : "other", PAT, g, 100 + i)).ok);
      for (const [m, ...a] of [["of", "ws"], ["of", "other"], ["get", "ws", ids[0]], ["get", "other", ids[0]], ["remove", "ws", ids[0]], ["remove", "ws", ids[0]], ["of", "ws"]])
        out.push((await mbCall(id, m!, ...a)).ok);
    }
    const db = new DatabaseSync(file);
    const rows = db.prepare("SELECT id,ws,body FROM devices ORDER BY rowid").all().map((r) => ({ ...r }));
    db.close();
    return { out, rows };
  };
  await same("the registry", run);
});

// ── the machine: what the program asks of it, done as the TypeScript does it itself ──


/// What both sides logged, as one list, while a case of the machine runs: `told` each line as it comes.
const logged: Json[] = [];
const heardLog = new Set<(l: Json) => void>();
const realLog = { info: log.info, warn: log.warn };
function captureLog() {
  logged.length = 0;
  log.info = (at, message, fields) => note(["info", at, message, plain(fields ?? null)]);
  log.warn = (at, message, fields) => note(["warn", at, message, plain(fields ?? null)]);
}
function note(l: Json) {
  logged.push(l);
  for (const h of [...heardLog]) h(l);
}
after(() => Object.assign(log, realLog));
/// Done once `n` lines saying `message` are logged.
async function loggedTimes(message: string, n: number): Promise<void> {
  while (logged.filter((l) => l[2] === message).length < n) await loggedOnce(message, logged.length);
}
/// Done once a line saying `message` is logged (from now, or already among `logged` from `from` on).
function loggedOnce(message: string, from = 0): Promise<void> {
  if (logged.slice(from).some((l) => l[2] === message)) return Promise.resolve();
  return new Promise((resolve) => {
    const h = (l: Json) => {
      if (l[2] !== message) return;
      heardLog.delete(h);
      resolve();
    };
    heardLog.add(h);
  });
}

/// A pipe in memory: what one end writes the other reads.
class Pipe {
  chunks: (Buffer | null)[] = [];
  waiters: (() => void)[] = [];
  push(b: Buffer | null) {
    this.chunks.push(b);
    for (const w of this.waiters.splice(0)) w();
  }
  async read(): Promise<Buffer | null> {
    while (this.chunks.length === 0) await new Promise<void>((r) => this.waiters.push(r));
    const c = this.chunks.shift()!;
    if (c === null) this.chunks.unshift(null);
    return c;
  }
}

/// A stream of a mesh connection, both ends in memory.
class MemStream {
  readonly toPhone = new Pipe();
  readonly toStation = new Pipe();
  finished = false;
  reset_: number | null = null;
  #stopped!: (v: number | null) => void;
  readonly stoppedP = new Promise<number | null>((r) => (this.#stopped = r));
  written = "";
  readonly heard = new Set<() => void>();
  // the station's end
  async read() {
    return this.toStation.read();
  }
  async write(b: Buffer) {
    if (this.reset_ !== null) throw new Error("the stream was reset");
    this.written += b.toString();
    this.toPhone.push(Buffer.from(b));
    for (const h of [...this.heard]) h();
  }
  async finish() {
    this.finished = true;
    this.toPhone.push(null);
    for (const h of [...this.heard]) h();
  }
  stopped() {
    return this.stoppedP;
  }
  async reset(code: number) {
    this.reset_ = code;
    this.toStation.push(null);
    this.toPhone.push(null);
    this.#stopped(code);
    for (const h of [...this.heard]) h();
  }
  /// The phone stops reading it (the offer's end, as the app stops sharing).
  stop() {
    this.#stopped(0);
  }
  lines(): Json[] {
    return this.written.split("\n").filter(Boolean).map((l) => {
      try {
        return JSON.parse(l);
      } catch {
        return l;
      }
    });
  }
  /// Done once what was written says `ok`.
  until(ok: (s: MemStream) => boolean): Promise<void> {
    if (ok(this)) return Promise.resolve();
    return new Promise((resolve) => {
      const h = () => {
        if (!ok(this)) return;
        this.heard.delete(h);
        resolve();
      };
      this.heard.add(h);
    });
  }
}

/// A phone's connection in memory: each stream the station opens on it answered by the phone (`answer`), as its core
/// takes a tunnel on to its adbd (a line each way, as the fake adb's handshake is).
class MemConn {
  readonly opened: MemStream[] = [];
  #closed!: (why: string) => void;
  readonly closedP = new Promise<string>((r) => (this.#closed = r));
  isClosed_ = false;
  readonly id: string;
  readonly answer: (s: MemStream) => Promise<void>;
  constructor(id: string, answer: (s: MemStream) => Promise<void>) {
    this.id = id;
    this.answer = answer;
  }
  remoteId() {
    return this.id;
  }
  async openBi() {
    const s = new MemStream();
    this.opened.push(s);
    void this.answer(s);
    return s;
  }
  closed() {
    return this.closedP;
  }
  isClosed() {
    return this.isClosed_;
  }
  close() {
    this.isClosed_ = true;
    this.#closed("closed");
  }
}

/// The phone's side of a tunnel: its head read, `{ok}` or an error said, and each line answered `ADBD <line>`.
function phone(refuse: Json = null) {
  return async (s: MemStream) => {
    let carry = "";
    const line = async (): Promise<string | null> => {
      for (;;) {
        const at = carry.indexOf("\n");
        if (at >= 0) {
          const l = carry.slice(0, at);
          carry = carry.slice(at + 1);
          return l;
        }
        const more = await s.toPhone.read();
        if (more === null) return null;
        carry += more.toString();
      }
    };
    const head = await line();
    if (head === null) return;
    if (refuse !== null) {
      s.toStation.push(Buffer.from(`${JSON.stringify(refuse)}\n`));
      s.toStation.push(null);
      return;
    }
    s.toStation.push(Buffer.from(`${JSON.stringify({ ok: true })}\n`));
    // (what adb writes last of a pairing, its peer info, is answered nothing: adb has ended by then)
    for (let l = await line(); l !== null; l = await line()) if (l !== "PEER") s.toStation.push(Buffer.from(`ADBD ${l}\n`));
    s.toStation.push(null);
  };
}

/// What the program asks of the machine, done here on real processes, sockets and files, and on the conns and
/// streams in memory the case names (`conns`, `streams`); `time` its clock; `more` what the case answers itself.
class Machine {
  readonly procs = new Map<number, { child: ChildProcess; said: string; ended: boolean; closed: Promise<void> }>();
  readonly listeners = new Map<number, { server: net.Server; accepted: (net.Socket | null)[]; waiters: (() => void)[] }>();
  readonly sockets = new Map<number, { socket: net.Socket; chunks: (Buffer | null)[]; waiters: (() => void)[]; closed: Promise<void>; read: boolean }>();
  readonly conns = new Map<string, MemConn>();
  readonly streams = new Map<string, MemStream>();
  #next = 0;
  readonly time: TestTime;
  readonly adb: string | null;
  readonly more: Asked;
  constructor(time: TestTime, adb: string | null, more: Asked = () => {
    throw new Error("no");
  }) {
    this.time = time;
    this.adb = adb;
    this.more = more;
  }
  /// Everything of the machine's let go (a case's end).
  async closeAll() {
    for (const l of this.listeners.values()) l.server.close();
    for (const s of this.sockets.values()) s.socket.destroy();
    // (each gone, not only killed, before the case ends: setup-env.mjs)
    await Promise.all([...this.procs.values()].map((p) => childGone(p.child, true)));
  }
  socketOf(socket: net.Socket): number {
    const id = ++this.#next;
    const s = { socket, chunks: [] as (Buffer | null)[], waiters: [] as (() => void)[], closed: new Promise<void>((r) => socket.once("close", () => r())), read: false };
    const wake = () => {
      for (const w of s.waiters.splice(0)) w();
    };
    socket.on("data", (b: Buffer) => (s.chunks.push(b), wake()));
    socket.on("end", () => (s.chunks.push(null), wake()));
    socket.on("close", () => (s.chunks.push(null), wake()));
    socket.on("error", () => {});
    this.sockets.set(id, s);
    return id;
  }
  streamId(s: MemStream): string {
    for (const [k, v] of this.streams) if (v === s) return k;
    const id = `s${++this.#next}`;
    this.streams.set(id, s);
    return id;
  }
  within<A>(ms: number, what: Promise<A>, why: string): Promise<A> {
    let stop = () => {};
    const late = new Promise<never>((_, reject) => (stop = this.time.after(ms, () => reject(new Error(why)))));
    return Promise.race([what, late]).finally(stop);
  }
  ask: Asked = async (name, args) => {
    const t = this.time;
    switch (name) {
      case "clock.sleep": return new Promise((r) => t.after(args[0], r, args[1]));
      case "clock.cancel": return void t.cancel(args[0]);
      case "log.info": case "log.warn": return void note([name.slice(4), args[0], args[1], args[2]]);
      case "adb.path": return this.adb;
      case "process.pid": return process.pid;
      case "platform.sep": return "/";
      case "platform.os": return platform.os;
      case "platform.startTimeOf": return platform.startTimeOf(args[0]);
      case "platform.tcpPortPids": return platform.tcpPortPids(args[0]);
      case "proc.signal": return void process.kill(args[0], args[1]);
      case "proc.run": {
        const o = args[0];
        const r = await platform.runnableSoon(o.file, o.args, process.env);
        return await new Promise((resolve, reject) => {
          const child = spawn(r.file, r.args, { stdio: ["ignore", "pipe", "pipe"], env: { ...process.env, ...(o.adbEnv ? { ADB_MDNS_AUTO_CONNECT: "0" } : {}) } });
          let out = "", err = "", timedOut = false;
          const stop = o.timeout == null ? () => {} : t.after(o.timeout, () => {
            timedOut = true;
            child.kill("SIGKILL");
          });
          child.stdout.on("data", (b) => (out += b));
          child.stderr.on("data", (b) => (err += b));
          child.on("error", (e) => (stop(), reject(e)));
          child.on("close", (code) => (stop(), resolve(timedOut ? { timedOut: true, code, out, err } : { code, out, err })));
        });
      }
      case "proc.start": {
        const o = args[0];
        const r = await platform.runnableSoon(o.file, o.args, process.env);
        const child = spawn(r.file, r.args, { env: { ...process.env, ...(o.adbEnv ? { ADB_MDNS_AUTO_CONNECT: "0" } : {}), ...(o.env ?? {}) }, stdio: ["ignore", "pipe", "pipe"] });
        const id = ++this.#next;
        const p = { child, said: "", ended: false, closed: new Promise<void>((res) => child.on("close", () => res())) };
        child.stdout!.on("data", (d) => (p.said += d));
        child.stderr!.on("data", (d) => (p.said += d));
        child.on("close", () => (p.ended = true));
        child.on("error", () => {});
        this.procs.set(id, p);
        return id;
      }
      case "proc.said": {
        const p = this.procs.get(args[0])!;
        return { said: p.said, ended: p.ended, exitCode: p.child.exitCode };
      }
      case "proc.kill": return void this.procs.get(args[0])?.child.kill(args[1] ?? "SIGTERM");
      case "proc.closed": return this.procs.get(args[0])!.closed;
      case "proc.pid": return this.procs.get(args[0])?.child.pid ?? null;
      case "net.freePort": {
        const s = net.createServer();
        await new Promise<void>((r) => s.listen({ host: "127.0.0.1", port: 0 }, r));
        const port = (s.address() as net.AddressInfo).port;
        await new Promise((r) => s.close(r));
        return port;
      }
      case "net.listen": {
        const o = args[0];
        const server = net.createServer({ pauseOnConnect: o.pauseOnConnect === true, allowHalfOpen: o.allowHalfOpen === true });
        const id = ++this.#next;
        const l = { server, accepted: [] as (net.Socket | null)[], waiters: [] as (() => void)[] };
        server.on("connection", (s) => (l.accepted.push(s), l.waiters.splice(0).forEach((w) => w())));
        server.on("close", () => (l.accepted.push(null), l.waiters.splice(0).forEach((w) => w())));
        await new Promise<void>((resolve, reject) => {
          server.once("error", reject);
          server.listen({ host: o.host, port: o.port, exclusive: o.exclusive === true }, () => (server.off("error", reject), resolve()));
        });
        server.on("error", () => {});
        this.listeners.set(id, l);
        return { id, port: (server.address() as net.AddressInfo).port };
      }
      case "net.accept": {
        const l = this.listeners.get(args[0])!;
        while (l.accepted.length === 0) await new Promise<void>((r) => l.waiters.push(r));
        const s = l.accepted[0]!;
        if (s === null) return null;
        l.accepted.shift();
        return this.socketOf(s);
      }
      case "net.close": {
        const l = this.listeners.get(args[0]);
        if (l === undefined) return null;
        await new Promise<void>((r) => l.server.close(() => r()));
        return null;
      }
      case "net.connect": {
        const o = args[0];
        const socket = net.connect(o.path ? { path: o.path, allowHalfOpen: o.allowHalfOpen === true } : { host: o.host ?? "127.0.0.1", port: o.port, allowHalfOpen: o.allowHalfOpen === true });
        const made = new Promise<net.Socket>((resolve, reject) => {
          socket.once("error", reject);
          socket.once("connect", () => (socket.off("error", reject), socket.pause(), resolve(socket)));
        });
        const s = o.timeout != null ? await this.within(o.timeout, made, o.why).catch((e) => (socket.destroy(), Promise.reject(e))) : await made;
        return this.socketOf(s);
      }
      case "net.first": {
        const s = this.sockets.get(args[0])!;
        s.socket.resume();
        while (s.chunks.length === 0) await new Promise<void>((r) => s.waiters.push(r));
        s.socket.pause();
        return s.chunks[0] !== null;
      }
      case "net.keep": {
        const s = this.sockets.get(args[0])!;
        s.socket.on("data", () => (s.chunks.length = 0));
        s.socket.resume();
        return null;
      }
      case "net.read": {
        const s = this.sockets.get(args[0])!;
        s.socket.resume();
        while (s.chunks.length === 0) await new Promise<void>((r) => s.waiters.push(r));
        const c = s.chunks[0]!;
        if (c === null) return null;
        s.chunks.shift();
        return c.toString("base64");
      }
      case "net.write": {
        const { socket } = this.sockets.get(args[0])!;
        if (socket.destroyed) throw new Error("the adb connection closed");
        if (socket.write(Buffer.from(args[1], "base64"))) return null;
        return new Promise((resolve, reject) => {
          socket.once("drain", () => resolve(null));
          socket.once("close", () => reject(new Error("the adb connection closed")));
        });
      }
      case "net.end": return void this.sockets.get(args[0])!.socket.end(args[1] ?? undefined);
      case "net.resume": return void this.sockets.get(args[0])!.socket.resume();
      case "net.destroy": return void this.sockets.get(args[0])?.socket.destroy();
      case "net.destroyed": return this.sockets.get(args[0])?.socket.destroyed ?? true;
      case "net.closed": return this.sockets.get(args[0])!.closed;
      case "net.remotePort": return this.sockets.get(args[0])!.socket.remotePort ?? null;
      case "net.join": {
        const a = this.sockets.get(args[0])!.socket, b = this.sockets.get(args[1])!.socket;
        for (const [from, to] of [[a, b], [b, a]] as const) {
          from.once("error", () => to.destroy());
          from.once("close", () => to.destroy());
          from.removeAllListeners("data");
          from.pipe(to);
          from.resume();
        }
        return null;
      }
      case "conn.remoteId": return this.conns.get(args[0])!.remoteId();
      case "conn.openBi": return this.streamId(await this.within(args[1], this.conns.get(args[0])!.openBi(), args[2]));
      case "conn.closed": return this.conns.get(args[0])!.closed();
      case "conn.isClosed": return this.conns.get(args[0])!.isClosed();
      case "conn.hasAnswers": return typeof (this.conns.get(args[0]) as Json).answers === "function";
      case "conn.answers": return (this.conns.get(args[0]) as Json).answers(args[1]);
      case "conn.about": {
        const c = this.conns.get(args[0])!;
        return { device: c.remoteId().slice(0, 12), via: "none", ways: "" };
      }
      case "stream.read": {
        const b = await this.streams.get(args[0])!.read();
        return b === null ? null : b.toString("base64");
      }
      case "stream.write": return this.streams.get(args[0])!.write(Buffer.from(args[1], "base64"));
      case "stream.finish": return this.streams.get(args[0])!.finish();
      case "stream.reset": return this.streams.get(args[0])!.reset(args[1]);
      case "stream.stopped": return this.streams.get(args[0])!.stopped();
      case "fs.read": return readFile(args[0], "utf8");
      case "fs.write": return void (await writeFile(args[0], args[1]));
      case "fs.rename": return void (await rename(args[0], args[1]));
      case "fs.rm": return void (await rm(args[0], { recursive: true, force: true }));
      case "fs.mkdir": return void (await mkdir(args[0], { recursive: true }));
      case "fs.copy": return void (await copyFile(args[0], args[1]));
      case "fs.realpath": return realpath(args[0]);
      case "fs.size": return (await stat(args[0])).size;
      case "random.int": return (await import("node:crypto")).randomInt(args[0], args[1]);
      case "fs.mkdtemp": return mkdtempSync(join(tmpdir(), args[0]));
      case "fs.stat": {
        const m = await stat(args[0]);
        return { isFile: m.isFile(), size: m.size };
      }
      case "fs.sha256": return createHash("sha256").update(await readFile(args[0])).digest("hex");
      default: return this.more(name, args);
    }
  };
}

/// What differs between the two sides' runs and says nothing of what each did: the ports and pids the machine gave
/// each, its temporary directories.
function normal(v: Json): Json {
  return JSON.parse(
    JSON.stringify(v)
      .replace(/127\.0\.0\.1:\d+/g, "127.0.0.1:PORT")
      .replace(/"(port|pid)":\d+/g, '"$1":0')
      .replace(/-P","\d+"/g, '-P","PORT"')
      .replace(/-P \d+/g, "-P PORT")
      .replace(/sf-adb-[A-Za-z0-9]+/g, "sf-adb-X")
      .replace(/mb-adb-[a-z-]+(ts|mb)-[A-Za-z0-9]+/g, "mb-adb-DIR"),
  );
}

test("a file staged in the session's uploads and fetched by the phone a part at a time", async () => {
  const content = randomBytes(5000);
  const run = async (side: "ts" | "mb") => {
    const ws = fresh(`send-${side}`);
    writeFileSync(join(ws, "app.apk"), content);
    mkdirSync(join(ws, "sub"));
    writeFileSync(join(ws, "we\u0001ird\\name"), "x");
    const out: Json[] = [];
    const m = new Machine(new TestTime(), null);
    asked = m.ask;
    for (const given of ["app.apk", "app.apk", join(ws, "app.apk"), "missing", "sub", "we\u0001ird\\name"])
      out.push(side === "ts" ? await ts(() => staged(ws, given)) : await mbFn("staged", ws, given));
    // What the phone says of the fetch: where it put it, how far it got, or that it is an app from before.
    const says: Json[][] = [
      [{ at: 100 }, { at: 4000 }, { path: "/sdcard/x" }], [{ at: 10 }, { error: "link went", at: 20 }], [{ error: "无法识别的通道" }], [{ at: 1 }], [{ error: "x" }, { at: 3 }],
    ];
    for (const lines of says) {
      const heard: number[] = [];
      let head: Json = null;
      const conn = new MemConn("ab".repeat(32), async (s) => {
        let all = "";
        for (let b = await s.toPhone.read(); b !== null; b = await s.toPhone.read()) all += b.toString();
        head = JSON.parse(all.trim());
        for (const l of lines) s.toStation.push(Buffer.from(`${JSON.stringify(l)}\n`));
        s.toStation.push(null);
      });
      if (side === "ts") out.push(await ts(() => fetchOnPhone(conn as any, "k", "n", 5000, (at) => heard.push(at))));
      else {
        m.conns.set("c", conn);
        const before = m.ask;
        asked = (name, a) => (name === "fetch.heard" ? void heard.push(a[0]) : before(name, a));
        out.push(await mbFn("fetchOnPhone", "c", "k", "n", 5000));
        asked = m.ask;
      }
      out.push(heard, head);
    }
    const listing = (await import("node:fs")).readdirSync(join(ws, "uploads")).sort();
    return normal({ out, listing });
  };
  await same("staged and fetched", run);
});

test("the door: the grant's own let through to its server, any other told why as adb's client reads it", async () => {
  const run = async (side: "ts" | "mb") => {
    const dir = fresh(`door-${side}`);
    const path = join(dir, "s");
    // The grant's adb server: it answers what it is sent with what it heard.
    const server = net.createServer({ allowHalfOpen: true }, (s) => {
      let heard = "";
      s.on("data", (b) => (heard += b));
      s.on("end", () => s.end(`server heard ${heard}`));
    });
    await new Promise<void>((r) => server.listen(path, r));
    const admitted: Json[] = [];
    const admit = async (id: string, holders: number[]) => {
      admitted.push([id, holders.includes(process.pid)]);
      return admitted.length === 2 ? "this phone is granted to another chat" : admitted.length === 3 ? null : null;
    };
    const m = new Machine(new TestTime(), null, async (name, args) => {
      if (name === "door.holders") return platform.tcpPortPids(args[0]);
      if (name === "door.admit") return admit(args[0], args[1]);
      throw new Error(name);
    });
    asked = m.ask;
    const door = side === "ts" ? await openDoor("g", path, (p) => platform.tcpPortPids(p), admit) : null;
    const port = door !== null ? door.port : (await mbFn("openDoor", "g", path)).ok;
    const talk = (what: string) =>
      new Promise<string>((resolve) => {
        const c = net.connect({ host: "127.0.0.1", port, allowHalfOpen: true });
        let heard = "";
        c.on("data", (b) => (heard += b));
        c.on("error", () => resolve(`cut: ${heard}`));
        c.once("connect", () => c.end(what));
        c.once("close", () => resolve(heard));
      });
    const out = [await talk("host:version"), await talk("host:devices"), await talk("shell:ls")];
    server.close();
    out.push(await talk("after the server went"));
    door?.close();
    await m.closeAll();
    return { out, admitted };
  };
  await same("the door", run);
});

/// A fake adb of a case's own: `server nodaemon` an adb server (on `-P <port>`, or on ADB_SERVER_SOCKET's path) that
/// answers what it is sent with what it heard; each invocation's argv written down in `calls`.
function fakeServerAdb(): { path: string; calls: () => Json[]; up: () => Promise<void>; expect: () => void; close: () => void } {
  const dir = fresh("server-adb");
  // (each server says it listens: what a wait between the station's pokes at it waits for, not the machine's time)
  const control = join(dir, "control");
  let listening = 0;
  const heard = new Set<() => void>();
  const ear = net.createServer((c) => {
    c.on("data", () => {});
    c.on("end", () => {
      listening++;
      for (const h of [...heard]) h();
    });
  });
  ear.listen(control);
  process.env.FAKE_ADB_CONTROL = control;
  /// How many servers the case has asked for so far: a wait between pokes comes due once they all listen.
  let expected = 0;
  const up = async () => {
    while (listening < expected) await new Promise<void>((r) => heard.add(r));
  };
  const js = join(dir, "adb.mjs");
  writeFileSync(js, `import fs from "node:fs"; import net from "node:net";
const args = process.argv.slice(2);
fs.appendFileSync(${JSON.stringify(join(dir, "calls"))}, JSON.stringify(args) + "\\n");
const p = args.indexOf("-P");
const socket = process.env.ADB_SERVER_SOCKET;
const server = net.createServer({ allowHalfOpen: true }, (s) => { let h = ""; s.on("error", () => {}); s.on("data", (b) => (h += b)); s.on("end", () => s.end("server heard " + h)); });
const told = () => { const c = net.connect(process.env.FAKE_ADB_CONTROL); c.on("error", () => {}); c.end("listening\\n"); };
if (socket) server.listen(socket.replace(/^localfilesystem:/, ""), told);
else server.listen(Number(args[p + 1]), "127.0.0.1", told);
`);
  const path = join(dir, "adb");
  script(path, `exec node '${js}' "$@"`);
  return { path: exe(path), up, expect: () => void expected++, close: () => ear.close(), calls: () => readFileSync(join(dir, "calls"), "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l)) };
}

test("the grants' adb servers: those a station before left stopped, one started for a grant, its door its session's", async () => {
  const run = async (side: "ts" | "mb") => {
    const t = new TestTime();
    // (a server's poke waits 100 ms between tries: those waits come due by themselves)
    t.auto = true;
    t.autoOnly = [100];
    // (a process's start is read off the machine's time, ps's elapsed from now: the TypeScript's now is the test's)
    if (side === "ts") tsTime(t);
    const dir = fresh(`servers-${side}`);
    const record = join(dir, "adb-servers.json");
    // What a station before left: a server still running, one whose pid another process took, one gone, and nonsense.
    const victim = spawn("sleep", ["60"], { stdio: "ignore" });
    const other = spawn("sleep", ["60"], { stdio: "ignore" });
    const started = await platform.startTimeOf(victim.pid!);
    const otherStarted = await platform.startTimeOf(other.pid!);
    const left = join(dir, "left-dir");
    mkdirSync(left);
    const victimEnded = new Promise((r) => victim.once("exit", (_c, sig) => r(sig)));
    writeFileSync(record, JSON.stringify([
      { pid: victim.pid, port: 1, started, dir: left }, { pid: other.pid, port: 2, started: otherStarted! + 5000 }, { pid: 2 ** 22 + 17, port: 3, started: null }, { pid: "x" }, null,
    ]));
    const adb = fakeServerAdb();
    t.gate = adb.up;
    const admitted: Json[] = [];
    const admit = async (id: string, holders: number[]) => (admitted.push([id, holders.includes(process.pid)]), admitted.length === 1 ? "not yours" : null);
    const m = new Machine(t, adb.path, async (name, args) => {
      if (name === "previous.gone") return null;
      if (name === "servers.admit") return admit(args[0], args[1]);
      throw new Error(name);
    });
    asked = m.ask;
    const out: Json[] = [];
    let servers: GrantServers | null = null;
    let doors: GrantServers | null = null;
    const id = partId("servers"), doorsId = partId("servers");
    if (side === "ts") {
      tsTime(t);
      servers = new GrantServers(() => adb.path, record);
      doors = new GrantServers(() => adb.path, null, admit);
      out.push(await servers.reap(Promise.resolve()));
    } else {
      mbTime = t;
      await mbNew({ kind: "servers", id, record });
      await mbNew({ kind: "servers", id: doorsId, admit: true });
      out.push((await mbCall(id, "reap")).ok);
    }
    out.push(await victimEnded, other.exitCode, readFileSync(record, "utf8"), (await import("node:fs")).existsSync(left));
    await childGone(other, true);
    // A grant's server, on its port; another behind its door.
    adb.expect();
    const one = side === "ts" ? plain(await servers!.ensure("g1")) : (await mbCall(id, "ensure", "g1")).ok;
    const port = one.port;
    out.push(side === "ts" ? servers!.ids() : (await mbCall(id, "ids")).ok);
    if (side === "ts") await servers!.written();
    else await mbCall(id, "written");
    out.push(JSON.parse(readFileSync(record, "utf8")).map((k: Json) => Object.keys(k)));
    const talk = (p: number, what: string) =>
      new Promise<string>((resolve) => {
        const c = net.connect({ host: "127.0.0.1", port: p, allowHalfOpen: true });
        let heard = "";
        c.on("data", (b) => (heard += b));
        c.on("error", () => resolve(`cut: ${heard}`));
        c.once("connect", () => c.end(what));
        c.once("close", () => resolve(heard));
      });
    out.push(await talk(port, "host:version"));
    adb.expect();
    const behind = side === "ts" ? plain(await doors!.ensure("g2")) : (await mbCall(doorsId, "ensure", "g2")).ok;
    out.push(await talk(behind.port, "first"), await talk(behind.port, "second"), admitted);
    if (side === "ts") {
      await servers!.close();
      await doors!.close();
    } else {
      await mbCall(id, "close");
      await mbCall(doorsId, "close");
    }
    out.push(adb.calls().map((c) => c.join(" ")));
    adb.close();
    await m.closeAll();
    Object.assign(wall, realWall);
    return normal(out);
  };
  await same("the servers", run);
});

// ── a phone's offer over its member link, with the fake adb ──

const FAKE = fileURLToPath(new URL("./fake", import.meta.url));

/// A fake adb of its own (test/fake/adb): what it was asked, what it says.
function fakeAdb(files: Record<string, string> = {}) {
  const dir = fresh("fake-adb");
  const path = join(dir, "adb");
  script(path, `FAKE_ADB_DIR='${dir}' exec '${join(FAKE, "adb")}' "$@"`);
  for (const [name, content] of Object.entries(files)) writeFileSync(join(dir, name), content);
  const lines = (name: string) => {
    try {
      return readFileSync(join(dir, name), "utf8").split("\n").filter(Boolean);
    } catch {
      return [];
    }
  };
  const calls = () => lines("calls").map((l) => JSON.parse(l) as string[]);
  /// Done once adb has been asked `n` things: told by its directory changing, as each ask is written down.
  const asked = async (n: number) => {
    if (calls().length >= n) return;
    await new Promise<void>((resolve) => {
      const w = watch(dir, () => {
        if (calls().length < n) return;
        w.close();
        resolve();
      });
      if (calls().length >= n) {
        w.close();
        resolve();
      }
    });
  };
  return { path: exe(path), calls, asked, dialed: () => lines("dialed"), say: (name: string, content: string) => writeFileSync(join(dir, name), content) };
}

const VIEWER = { sub: "u1", email: "Pat@Example.com", name: "Pat", role: "member", workspace: "ws", device: "d" };

/// What a case of a phone's offers does, the same on either side: offers made, asks answered, the clock moved on.
type Lending = {
  /// An offer on `conn` (its phone answering as `phone` says): its stream, held open.
  offer(conn: MemConn, ask: Json, headers?: Json): MemStream;
  /// An ask of the phone's offer (`pair`, `grant`, another): what it was answered.
  ask(conn: MemConn, ask: Json, headers?: Json): Promise<Json>;
  list(): Promise<Json>;
  gone(): Promise<Json>;
  time: TestTime;
  fake: ReturnType<typeof fakeAdb>;
  /// Every offer's own run done (its stream finished, or reset).
  ended(): Promise<void>;
};

async function lending(side: "ts" | "mb", files: Record<string, string>, script: (l: Lending) => Promise<Json>) {
  const t = new TestTime();
  t.auto = true;
  // (adb's state looked at every 500 ms until it settles: those waits come due by themselves; the others the case's)
  t.autoOnly = [500];
  const fake = fakeAdb(files);
  // (`noAdb`: the machine has none)
  const adb = files.noAdb === undefined ? fake.path : null;
  captureLog();
  const stated: Json[] = [];
  const runs: Promise<unknown>[] = [];
  const m = new Machine(t, adb);
  let shares: Shares | null = null;
  const id = partId("shares");
  if (side === "ts") {
    tsTime(t);
    shares = new Shares({ adb: () => adb, clock: effectClock(t), limits: { quick: null, long: null }, stated: (email, state) => void stated.push([email, plain(state)]) });
  } else {
    mbTime = t;
    asked = async (name, args) => (name === "shares.stated" ? void stated.push(args) : m.ask(name, args));
    await mbNew({ kind: "shares", id, limits: { quick: null, long: null } });
  }
  let n = 0;
  const call = (conn: MemConn, stream: MemStream, head: Json) => {
    if (side === "ts") return answerAdb(shares!, conn as any, VIEWER as any, head, stream as any);
    m.conns.set(conn.id, conn);
    const sid = `o${++n}`;
    m.streams.set(sid, stream);
    return mbCall(id, "answerAdb", conn.id, VIEWER, head, sid).then((o) => {
      if ("error" in o) throw new Error(o.error);
    });
  };
  const l: Lending = {
    time: t,
    fake,
    offer: (conn, ask, headers = {}) => {
      const s = new MemStream();
      runs.push(call(conn, s, { adb: { op: "share", ...ask }, headers }).catch((e) => s.lines().push({ threw: e.message })));
      return s;
    },
    ask: async (conn, ask, headers = {}) => {
      const s = new MemStream();
      await call(conn, s, { adb: ask, headers });
      return { finished: s.finished, said: s.written.split("\n").map((p) => p) };
    },
    list: async () => (side === "ts" ? plain(shares!.list()) : (await mbCall(id, "list")).ok),
    gone: async () => (side === "ts" ? plain(Object.fromEntries(shares!.gone)) : (await mbCall(id, "gone")).ok),
    ended: async () => void (await Promise.all(runs)),
  };
  const out = await script(l);
  if (side === "ts") await shares!.close();
  else await mbCall(id, "close");
  await m.closeAll();
  Object.assign(wall, realWall);
  return normal({ out, stated, calls: fake.calls(), dialed: fake.dialed(), logged: [...logged] });
}

/// A phone's connection, its key `id` (hex), its tunnels answered as `phone(refuse)` does.
const phoneConn = (id: string, refuse: Json = null) => new MemConn(id, phone(refuse));

test("a phone offered: adb connects through its tunnel, keeps it lending, is asked to pair and grant, lets it go", async () => {
  await words("zh");
  // (a phone of this run's own: its usual port is another run's at once otherwise)
  const PHONE = randomBytes(32).toString("hex");
  await same("an offer", (side) =>
    lending(side, {}, async (l) => {
      const out: Json[] = [];
      const a = phoneConn("c1".repeat(32));
      const offerA = l.offer(a, { phone: PHONE, device: "Pixel\u0007 9", android: "16", package: "fail.still", adbd: true, pair: true, connect: 41000 }, { "StillFail-Lang": "en" });
      await offerA.until((s) => s.lines().some((x) => x.adb === "connected"));
      await loggedOnce("adb asked for adbd's plain port");
      out.push(await l.list());
      out.push(await l.ask(a, { op: "grant", phone: PHONE }, { "stillfail-lang": "en" }));
      l.fake.say("grant-says", "java.lang.SecurityException: needs GRANT_RUNTIME_PERMISSIONS");
      out.push(await l.ask(a, { op: "grant", phone: PHONE }));
      l.fake.say("grant-says", "Error: something else\nat line");
      out.push(await l.ask(a, { op: "grant", phone: PHONE }, { "stillfail-lang": "en" }));
      l.fake.say("grant-says", "");
      out.push(await l.ask(a, { op: "pair", phone: PHONE, code: "12" }));
      const asks = l.fake.calls().length;
      out.push(await l.ask(a, { op: "pair", phone: PHONE, code: "12 34-56" }, { "stillfail-lang": "en" }));
      // (connected again after the pairing, in the background: its state looked at, what keeps it lending asked again,
      // adbd's plain port looked at; each step after it, as a person would come to it)
      await l.fake.asked(asks + 5);
      out.push(await l.ask(a, { op: "pair", phone: PHONE, code: "654321" }));
      out.push(await l.ask(a, { op: "nonsense", phone: PHONE }));
      out.push(await l.ask(a, { op: "grant", phone: "cd".repeat(32) }, { "stillfail-lang": "en" }));
      // Another offer of the same phone, on another link: nothing asked of adb again.
      const b = phoneConn("c2".repeat(32));
      const offerB = l.offer(b, { phone: PHONE, device: "Pixel 9", android: "16", package: "fail.still", adbd: true, pair: false, connect: 41000 });
      await offerB.until((s) => s.lines().length >= 2);
      // The first offer ends: the latest holds the phone.
      offerA.stop();
      await l.time.waitFor(5000);
      await l.time.advance(5000);
      await offerA.until((s) => s.finished);
      out.push(await l.list());
      // The latest ends: let go after a moment, adb told.
      offerB.stop();
      await l.time.waitFor(5000);
      await l.time.advance(5000);
      await offerB.until((s) => s.finished);
      await l.ended();
      out.push(await l.list(), await l.gone(), offerA.lines(), offerB.lines());
      return out;
    }),
  );
});

test("a phone not reached: its tunnel refused unpaired, Wireless debugging off, adb unauthorized, adb missing", async () => {
  const OTHER = randomBytes(32).toString("hex");
  await words("zh");
  const cases: [string, Record<string, string>, Json, Json][] = [
    ["refused, not paired", {}, { error: "无线调试未配对", unpaired: true }, { adbd: true }],
    ["refused, its adbd not there", {}, { error: "adbd 不在" }, { adbd: true, package: "x;y" }],
    ["Wireless debugging off", {}, null, { adbd: false }],
    ["unauthorized", { "on-connect": "unauthorized" }, null, { adbd: true }],
    ["never settled", { "on-connect": "offline" }, null, { adbd: true }],
    ["adb missing", { noAdb: "" }, null, { adbd: true }],
  ];
  for (const [what, files, refuse, ask] of cases)
    await same(what, (side) =>
      lending(side, files, async (l) => {
        const c = phoneConn("c3".repeat(32), refuse);
        const offer = l.offer(c, { phone: OTHER, device: "Mi", android: "14", ...ask });
        await offer.until((s) => s.lines().some((x) => x.adb !== undefined && x.adb !== "connecting"));
        await loggedOnce("adb holds the phone");
        const out = [await l.list(), offer.lines()];
        offer.stop();
        await l.time.waitFor(5000);
        await l.time.advance(5000);
        await offer.until((s) => s.finished);
        await l.ended();
        return out;
      }),
    );
});

// ── a chat's display on the phone ──

/// A fake adb for a chat's display: the phone's screen as wm says it, scrcpy's server that makes a display and keeps
/// it while it runs (saying so to the test, as it starts and as it is ended), its forward to a listener of the test's
/// that sends its first byte once the server has started, and what dumpsys and am say. Each argv written in `calls`.
function displayAdb() {
  const dir = fresh("display-adb");
  const control = join(dir, "control");
  const said = { started: 0, ended: 0, removed: 0 };
  const heard = new Set<() => void>();
  const ear = net.createServer((c) => {
    let what = "";
    c.on("data", (b) => (what += b));
    c.on("error", () => {});
    const tell = (k: keyof typeof said) => {
      said[k]++;
      for (const h of [...heard]) h();
    };
    c.on("end", () => what.trim() === "removed" && tell("removed"));
    let told = false;
    c.on("data", () => what.startsWith("started") && !told && ((told = true), tell("started")));
    c.on("close", () => what.startsWith("started") && tell("ended"));
  });
  ear.listen(control);
  // The forward's other end: its first byte once a server has started.
  /// How many servers the case has asked for: a forward's first byte waits for that many to have started.
  let wanted = 0;
  const forward = net.createServer((c) => {
    c.on("error", () => {});
    const go = () => (said.started >= wanted ? c.write("x") : void heard.add(once));
    const once = () => (heard.delete(once), go());
    go();
  });
  const js = join(dir, "adb.mjs");
  writeFileSync(js, `import fs from "node:fs"; import net from "node:net";
const dir = ${JSON.stringify(dir)};
const args = process.argv.slice(2);
fs.appendFileSync(dir + "/calls", JSON.stringify(args) + "\\n");
const at = args.indexOf("shell");
const cmd = at >= 0 ? args.slice(at + 1).join(" ") : "";
const file = (n) => { try { return fs.readFileSync(dir + "/" + n, "utf8"); } catch { return ""; } };
const tell = (what, keep) => { const c = net.connect(dir + "/control"); c.on("error", () => {}); c.write(what); if (!keep) c.end(); return c; };
if (cmd.includes("getprop ro.build.version.sdk")) process.stdout.write(file("sdk") || "34\\n");
else if (cmd.includes("wm size")) process.stdout.write("Physical size: 1080x2400\\n");
else if (cmd.includes("wm density")) process.stdout.write("Physical density: 420\\n");
else if (cmd.includes("stat -c %s")) process.stdout.write(file("jar-size"));
else if (cmd.includes("app_process")) { process.stdout.write("[server] INFO: Device: x\\n[server] INFO: New display: 1080x2400/420 (id=12)\\n"); tell("started", true); setInterval(() => {}, 1 << 30); }
else if (cmd.includes("dumpsys SurfaceFlinger --display-id")) process.stdout.write(file("ids"));
else if (cmd.includes("dumpsys SurfaceFlinger")) process.stdout.write(file("flinger"));
else if (cmd.includes("dumpsys display")) process.stdout.write(file("displays"));
else if (cmd.includes("am stack list")) process.stdout.write(file("stack"));
else if (cmd.includes("am stack remove")) {}
else if (args.includes("push")) process.stdout.write("1 file pushed\\n");
else if (args.includes("--remove")) tell("removed");
else if (args.includes("forward")) process.stdout.write(file("fwd-port") + "\\n");
else { process.stderr.write("fake adb: unknown " + args.join(" ") + "\\n"); process.exit(1); }
`);
  const path = join(dir, "adb");
  script(path, `exec node '${js}' "$@"`);
  writeFileSync(join(dir, "displays"), `    mBaseDisplayInfo=DisplayInfo{"scrcpy", displayId 12, displayGroupId 2, FLAG_PRESENTATION, real 1080 x 2400, type VIRTUAL, uniqueId "virtual:com.android.shell,2000,scrcpy,0", owner com.android.shell (uid 2000)}\n`);
  writeFileSync(join(dir, "ids"), `Display 11529215046400789845 (Virtual display): displayName="scrcpy" uniqueId="virtual:com.android.shell,2000,scrcpy,0"\n`);
  writeFileSync(join(dir, "stack"), "RootTask id=7723 bounds=[0,0][1080,2400] displayId=12 userId=0\nRootTask id=7720 displayId=0 userId=0\nRootTask id=7725 displayId=12\n");
  const until = async (k: keyof typeof said, n: number) => {
    while (said[k] < n) await new Promise<void>((r) => heard.add(function h() { heard.delete(h); r(); }));
  };
  return {
    path: exe(path), dir, said, until, want: () => void wanted++,
    listen: async () => {
      await new Promise<void>((r) => forward.listen(0, "127.0.0.1", r));
      writeFileSync(join(dir, "fwd-port"), String((forward.address() as net.AddressInfo).port));
    },
    calls: () => readFileSync(join(dir, "calls"), "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l) as string[]),
    close: () => (ear.close(), forward.close()),
  };
}

test("a chat's own display on the phone: made by scrcpy's server, found by SurfaceFlinger's id, closed with its apps", async () => {
  await same("a display", async (side) => {
    const t = new TestTime();
    t.auto = true;
    // (what scrcpy says looked for every 100 ms: those waits come due by themselves; the idle check the case's)
    t.autoOnly = [100];
    const adb = displayAdb();
    await adb.listen();
    const jar = join(fresh(`display-${side}`), "scrcpy-server");
    writeFileSync(jar, "jar".repeat(100));
    captureLog();
    const used = new Map<string, number | null>([["g1", t.now], ["g2", t.now]]);
    const changed: string[] = [];
    const m = new Machine(t, adb.path);
    const id = partId("displays");
    let d: PhoneDisplays | null = null;
    if (side === "ts") {
      tsTime(t);
      d = new PhoneDisplays({ adb: () => adb.path, usedAt: (g) => used.get(g) ?? null, changed: (o) => void changed.push(o), file: jar });
    } else {
      mbTime = t;
      asked = async (name, args) => {
        if (name === "displays.usedAt") return used.get(args[0]) ?? null;
        if (name === "displays.changed") return void changed.push(args[0]);
        return m.ask(name, args);
      };
      await mbNew({ kind: "displays", id, file: jar });
    }
    const call = async (name: string, ...args: Json[]) => (side === "ts" ? ts(() => (d as Json)[name](...args)) : mbCall(id, name, ...args));
    const out: Json[] = [];
    adb.want();
    out.push(await call("open", "g1", "pat@example.com", "Chat A", 5040, "127.0.0.1:37001"));
    out.push(await call("open", "g1", "pat@example.com", "Chat A renamed", 5040, "127.0.0.1:37001"));
    out.push(await call("titles", "pat@example.com"), await call("has", "g1"), await call("has", "g2"));
    // Its jar there already now (the same size): not put again.
    writeFileSync(join(adb.dir, "jar-size"), "300\n");
    writeFileSync(join(adb.dir, "sdk"), "31\n");
    adb.want();
    out.push(await call("open", "g2", "pat@example.com", "Chat B", 5041, "127.0.0.1:37001"));
    out.push(await call("titles", "pat@example.com"));
    // Handed back: its apps closed, scrcpy ended, its forward removed; done once the phone is through with it.
    out.push(await call("close", "g2"));
    await adb.until("removed", 1);
    out.push(await call("titles", "pat@example.com"), await call("has", "g2"));
    // Used a minute ago: kept at the next look; nothing of the agent's for ten minutes: closed.
    t.now += 9 * 60_000;
    used.set("g1", t.now);
    await t.waitFor(60_000);
    await t.advance(60_000);
    out.push(await call("has", "g1"));
    t.now += 10 * 60_000;
    // (the next look's wait under way first: the program sets it again once the last look is through, which its
    // answer to `has` can come before)
    await t.waitFor(60_000);
    await t.advance(60_000);
    await adb.until("removed", 2);
    out.push(await call("has", "g1"), changed, t.waiting());
    adb.close();
    await m.closeAll();
    Object.assign(wall, realWall);
    const calls = adb.calls().map((c) => c.join(" ").replace(/scrcpy_[0-9a-f]{8}/g, "scrcpy_SCID").replace(/scid=[0-9a-f]{8}/g, "scid=SCID").replace(/tcp:\d+/g, "tcp:PORT").replace(new RegExp(jar.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), "g"), "JAR"));
    return normal({ out, calls, logged: [...logged] });
  });
});

// ── the devices as a part of the station ──


/// The station's parts as a test holds them: what each part added.
function partsOf() {
  const tools: Json[] = [];
  const routes: Json[] = [];
  const streams = new Map<string, (ask: Json) => Promise<void>>();
  return {
    tools, routes, streams,
    parts: {
      tools: (t: Json[]) => void tools.push(...t),
      routes: (r: Json) => void routes.push(...(typeof r === "function" ? r({}) : r)),
      streams: (k: string, f: Json) => void streams.set(k, f),
    },
    tool: (name: string) => tools.find((t) => t.name === name)!,
    async route(method: string, path: string, viewer: Json, body = "") {
      for (const r of routes) {
        const m = r.method === method ? r.pattern.exec(path) : null;
        if (m) {
          const a = await r.handle({ viewer, body: Buffer.from(body) }, m.slice(1));
          return { status: a.status, body: JSON.parse(a.body.toString()) };
        }
      }
      return null;
    },
  };
}

/// A part of the station made in a scope of its own, on what it is given.
async function built(layer: Layer.Layer<never, never, any>, given: [any, unknown][]) {
  const scope = Effect.runSync(Scope.make());
  const provided = layer.pipe(Layer.provide(Layer.mergeAll(...given.map(([tag, v]) => Layer.succeed(tag, v as never)) as [Layer.Layer<any>, ...Layer.Layer<any>[]])));
  await Effect.runPromise(Layer.buildWithScope(provided as any, scope));
  return () => Effect.runPromise(Scope.close(scope, Exit.void));
}

test("the workspace's devices: attached here, on the other stations, on a tasks-only station; listed, used, handed back", async () => {
  const camera = net.createServer((s) => s.on("data", (b) => s.write(b.toString().toUpperCase())));
  await new Promise<void>((r) => camera.listen(0, "127.0.0.1", r));
  const cam = (camera.address() as net.AddressInfo).port;
  const ids: string[] = [];
  await same("the devices", async (side) => {
    const t = new TestTime();
    t.auto = true;
    // (a station that does not answer in time is left out: its wait comes due by itself)
    t.autoOnly = [2000];
    const file = join(fresh(`devices-${side}`), "db");
    const log: Json[] = [];
    const peers = [{ id: "st-self", name: "Self" }, { id: "st-b", name: "B" }, { id: "st-c", name: "C" }, { id: "st-d", name: "D" }, null, { id: 5 }];
    const cloud = {
      state: { station: "st-self" },
      memberships: () => [{ workspace: "ws", peers }, { workspace: "ws2", peers: [] }],
      membership: (ws: string) => (ws === "ws" ? { workspace: "ws", peers } : ws === "ws2" ? { workspace: "ws2", peers: [] } : null),
      home: () => "ws",
    };
    const sessions: Record<string, Json> = { s1: { ws: "ws", workspace: "/w/s1" }, s2: { ws: null, workspace: "/w/s2" } };
    const store = { getSession: (k: string) => sessions[k] ?? null, starter: () => "pat@example.com" };
    const remoteAsk = async (id: string, req: Json) => {
      log.push(["remote", id, req]);
      if (id === "st-b") return { devices: [{ id: "bbbbbbbbbbbbbbbb", name: "printer", kind: "tcp", target: "10.0.0.9:9100", owner: "kim", owner_email: "kim@example.com", owner_name: "Kim", baud: 9600 }] };
      if (id === "st-c") throw new Error("no link");
      return new Promise(() => {});
    };
    const rigs = {
      list: async () => [{ id: "rrrrrrrrrrrrrrrr", name: "board", kind: "serial", target: "/dev/tty", via: "rig", station: "st-r", stationName: "R", owner: "kim", ownerEmail: "kim@example.com", ownerName: "Kim", thisChat: "ask", hasAccess: [] }],
      use: async (_ws: string, s: string, e: Json, reason: string) => (log.push(["rigs.use", s, e.id, reason]), `rig: ${reason}`),
      done: (_ws: string, s: string, e: Json) => (log.push(["rigs.done", s, e?.id ?? null]), e === null ? ["board"] : [e.name]),
    };
    const forwards = {
      openDevice: async (s: string, station: string, target: Json, here: boolean) => {
        log.push(["open", s, station, target.id, target.name, here]);
        if (target.name === "printer" && s === "s2") throw Object.assign(new PeerRefused("st-b refused it"), { kind: "PeerRefused" });
        return { local: "127.0.0.1:4100" };
      },
      closeDevice: (s: string | null, id: string | null, why: string) => void log.push(["close", s, id, why]),
    };
    const m = new Machine(t, null);
    const id = partId("devices");
    const p = partsOf();
    let side_: Json = null;
    let bus: Json = null;
    let close = async () => {};
    if (side === "ts") {
      tsTime(t);
      const db = new DatabaseSync(file);
      const sources: Json = { rigs, phones: null, forward: null, changed: null };
      side_ = { device: null };
      close = await built(DevicesLive as any, [
        [services.ControlPlane, { state: cloud }], [services.Parts, p.parts], [services.Store, { ...store, db }],
        [services.Events, { tell: (...a: Json[]) => void log.push(["tell", ...plain(a)]) }], [services.MeshSide, side_], [services.DeviceSources, sources],
        [services.Paths, { data: fresh("data") }],
        [Agents, { hub: {}, remote: { bus: { on: (name: string, f: Json) => (bus = [name, f]) }, ask: remoteAsk }, forwards }],
      ]);
    } else {
      mbTime = t;
      let left = [...ids];
      asked = async (name, args) => {
        switch (name) {
          case "cloud.station": return "st-self";
          case "cloud.nameOf": return peers.find((x) => x?.id === args[0])?.name ?? args[0];
          case "cloud.peers": return cloud.membership(args[0])?.peers ?? [];
          case "cloud.memberships": return cloud.memberships();
          case "cloud.home": return cloud.home();
          case "events.tell": return void log.push(["tell", ...args]);
          case "remote.ask": return remoteAsk(args[0], args[1]);
          case "rigs.list": return rigs.list();
          case "rigs.use": return rigs.use(args[0], args[1], args[2], args[3]);
          case "rigs.done": return rigs.done(args[0], args[1], args[2]);
          case "forwards.openDevice": return forwards.openDevice(args[0], args[1], args[2], args[3]);
          case "forwards.closeDevice": return forwards.closeDevice(args[0], args[1], args[2]);
          case "random.hex": return left.shift() ?? "0000000000000000";
          default:
            if (name.startsWith("store.")) return (store as Json)[name.slice(6)](...args);
            return m.ask(name, args);
        }
      };
      await mbNew({ kind: "devices", id, db: file, rigs: true });
    }
    const out: Json[] = [];
    const PAT = { sub: "pat", email: "Pat@Example.com", name: "Pat", role: "member", workspace: "ws" };
    const ADMIN = { sub: "ann", email: "ann@example.com", name: "Ann", role: "admin", workspace: "ws" };
    const KIM = { sub: "kim", email: "kim@example.com", name: "Kim", role: "member", workspace: "ws" };
    const route = async (method: string, path: string, viewer: Json, body = "") => {
      if (side === "ts") return p.route(method, path, viewer, body);
      return (await mbCall(id, "route", method, path, viewer, body)).ok;
    };
    const tool = async (name: string, session: string, args: Json) => {
      if (side === "ts") return ts(() => p.tool(name).run(session, args));
      return name === "device_list" ? mbCall(id, "deviceList", session) : mbCall(id, "deviceUse", session, args);
    };
    for (const body of [JSON.stringify({ name: "cam", kind: "tcp", target: `127.0.0.1:${cam}` }), JSON.stringify({ name: "CAM", kind: "tcp", target: "1.2.3.4:5" }), "not json", "[1]",
      JSON.stringify({ name: "pixel", kind: "adb", target: "R5CT" }), JSON.stringify({ name: "printer", kind: "serial", target: "/dev/ttyS0" })]) {
      const r = await route("POST", "/devices", PAT, body);
      if (side === "ts") ids.push(r?.body?.device?.id ?? "0000000000000000");
      out.push(r);
    }
    out.push(await route("GET", "/devices", PAT));
    out.push(await tool("device_list", "s1", {}));
    for (const args of [{ device: "cam" }, { device: "CAM", reason: "x" }, { device: "printer" }, { device: "board", reason: "flash", timeout: { kind: "idle", seconds: 60 } },
      { device: "nothing" }, { device: "kim@example.com" }, {}, { device: "pixel" }, { device: "bbbbbbbbbbbbbbbb" }])
      out.push([args, await tool("device_use", "s1", args)]);
    out.push(await tool("device_use", "s2", { device: "bbbbbbbbbbbbbbbb" }));
    out.push(await tool("device_use", "s9", { device: "cam" }));
    for (const args of [{ done: true }, { done: true, device: "board" }, { done: true, device: "cam" }, { done: true, device: "nope" }])
      out.push([args, await tool("device_use", "s1", args)]);
    const camId = ids[0]!;
    // Another station's chat reaching a device here.
    if (side === "ts") {
      out.push(await ts(() => side_.device("peer", "ws", "s", camId, true)), await ts(() => side_.device("peer", "ws2", "s", camId, true)));
      const s = await side_.device("peer", "ws", "s", camId, false);
      out.push(typeof s?.pipe === "function");
      s.destroy();
      out.push(await ts(() => bus[1]("peer", {}, "ws")), bus[0]);
    } else {
      out.push(await mbCall(id, "sideDevice", "ws", camId, true), await mbCall(id, "sideDevice", "ws2", camId, true));
      const s = await mbCall(id, "sideDevice", "ws", camId, false);
      out.push(typeof s.ok === "number");
      await m.ask("net.destroy", [s.ok]);
      out.push(await mbCall(id, "busList", "ws"), "devices.list");
    }
    out.push(await route("DELETE", `/devices/${camId}`, KIM), await route("DELETE", "/devices/0123456789abcdef", PAT), await route("DELETE", `/devices/${ids[4]}`, ADMIN), await route("DELETE", `/devices/${camId}`, PAT));
    out.push(await route("GET", "/devices", PAT), await route("PUT", "/devices", PAT));
    await close();
    await m.closeAll();
    Object.assign(wall, realWall);
    return normal({ out, log }).toString === undefined ? null : JSON.parse(JSON.stringify(normal({ out, log })).replaceAll(String(cam), "CAM"));
  });
  camera.close();
});

test("the phones' part: a phone lent, asked for by a chat, decided and taken back from its owner's app, listed among the devices", async () => {
  await words("zh");
  const PHONE = randomBytes(32).toString("hex");
  const pathBefore = process.env.PATH;
  const homeBefore = process.env.HOME;
  delete process.env.ANDROID_HOME;
  delete process.env.ANDROID_SDK_ROOT;
  await same("the phones' part", async (side) => {
    const t = new TestTime();
    t.auto = true;
    t.autoOnly = [500];
    const fake = fakeAdb();
    captureLog();
    const data = fresh(`adb-part-${side}`);
    mkdirSync(join(data, "run"));
    const file = join(data, "db");
    const w = grantsWorld(file);
    const log: Json[] = [];
    const notified: Json[] = [];
    const stated: Json[] = [];
    const store = {
      ...w.store,
      sessionThread: (_s: string, channel: string, ts: string) => (channel === "CHAT" && ts === "1.0" ? { thread: { id: 1, surface: STILLFAIL_SURFACE, channel: "CHAT" } } : null),
      firstText: () => null,
      sessionChat: () => null,
    };
    const hub = {
      store,
      chat: (connect: string) => ({ post: async (where: Json, text: string) => w.post(connect, where, text) }),
      shared: (thread: number, n: number, session: string, text: string) => w.log.push(["shared", thread, n, session, text]),
      notify: (s: string, text: string) => void notified.push([s, text]),
    };
    const m = new Machine(t, fake.path);
    const id = partId("adb");
    const p = partsOf();
    const sources: Json = { rigs: null, phones: null, forward: null, changed: (ws: Json) => void log.push(["changed", ws]) };
    let close = async () => {};
    if (side === "ts") {
      tsTime(t);
      // (the station's adb is found on PATH: this side's fake, and no other: not the machine's own, wherever it is)
      process.env.PATH = [join(fake.path, ".."), join(process.execPath, ".."), "/usr/bin", "/bin"].join(delimiter);
      process.env.HOME = data;
      close = await built(AdbLive as any, [
        [services.ControlPlane, { state: { home: () => "home", state: { station: "st-self" }, removed: () => false, listen: () => () => {} } }],
        [services.Parts, p.parts], [Agents, { hub, cardOutcomes: undefined }], [services.Store, { ...store, db: w.db }],
        [services.Events, { tell: (...a: Json[]) => void log.push(["tell", ...plain(a)]) }], [services.ScreenRegistry, { refresher: () => () => {} }],
        [services.DeviceSources, sources], [services.Paths, { data }], [services.Previous, { gone: Promise.resolve() }],
      ]);
    } else {
      mbTime = t;
      w.db.close();
      asked = async (name, args) => {
        switch (name) {
          case "store.has": return false;
          case "hub.has": return false;
          case "hub.identity": return null;
          case "hub.shared": return void hub.shared(args[0], args[1], args[2], args[3]);
          case "hub.notify": return void notified.push(args);
          case "chat.post": return w.post(args[0], args[1], args[2]);
          case "store.insertMessage": return w.writtenAsync(args[0], args[1] ? async () => mbCb(args[1]) : undefined);
          case "store.restateCard": {
            const was = w.cards.find((x) => x.ts === args[2])?.card;
            const made = await mbCb(args[3], was ?? null);
            return w.store.restateCard(args[0], args[1], args[2], () => made);
          }
          case "grants.home": return "home";
          case "grants.id": return null;
          case "events.tell": return void log.push(["tell", ...args]);
          case "sources.changed": return void log.push(["changed", args[0]]);
          case "cloud.station": return "st-self";
          case "cloud.removed": return false;
          case "cloud.removedLater": return new Promise(() => {});
          case "previous.gone": return null;
          default:
            if (name.startsWith("store.")) return (store as Json)[name.slice(6)](...args);
            return m.ask(name, args);
        }
      };
      await mbNew({ kind: "adb", id, db: file, file: join(data, "scrcpy-server"), record: join(data, "run", "adb-servers.json"), admit: true });
    }
    const PAT = { sub: "u1", email: "Pat@Example.com", name: "Pat", role: "member", workspace: "work-a", device: "d" };
    const VIEWER_RO = { ...PAT, role: "viewer" };
    let n = 0;
    const stream = (conn: MemConn, viewer: Json, head: Json) => {
      const s = new MemStream();
      let done: Promise<unknown>;
      if (side === "ts") done = p.streams.get("adb")!({ conn, viewer, head, stream: s, reader: null });
      else {
        m.conns.set(conn.id, conn);
        const sid = `a${++n}`;
        m.streams.set(sid, s);
        done = mbCall(id, "stream", conn.id, viewer, head, sid);
      }
      return { s, done };
    };
    const ask = async (head: Json, viewer: Json = PAT) => {
      const { s, done } = stream(phoneConn("aa".repeat(32)), viewer, head);
      await done;
      return s.lines();
    };
    const tool = async (name: string, session: string, args: Json) => {
      if (side === "ts") return ts(() => p.tool(name).run(session, args));
      return name === "adb_devices" ? mbCall(id, "adbDevices") : name === "phone_use" ? mbCall(id, "phoneUse", session, args) : mbCall(id, "phoneSend", session, args);
    };
    const phones = async (what: string, ...args: Json[]) => {
      if (side === "ts") return ts(() => (sources.phones as Json)[what](...args));
      const name = { list: "phoneEntries", use: "phoneDeviceUse", done: "phoneDone", shown: "phonesShown" }[what]!;
      return mbCall(id, name, ...(what === "list" ? [args[1]] : what === "use" ? [args[1], args[2], args[3]] : what === "done" ? [args[1], args[2]] : [args[0]]));
    };
    const out: Json[] = [];
    out.push(await ask({ adb: { op: "grants" } }, VIEWER_RO));
    out.push(await tool("adb_devices", "s1", {}), await tool("phone_send", "s1", { path: "x" }));
    // The phone lent.
    const offer = stream(phoneConn("c5".repeat(32)), PAT, { adb: { op: "share", phone: PHONE, device: "Pixel 9", android: "16", package: "fail.still", adbd: true, pair: false, connect: 5555 } });
    await offer.s.until((s) => s.lines().some((x) => x.adb === "connected"));
    // (what keeps it lending done too: each step after it, as a person would come to it)
    const kept = () => logged.filter((x) => x[2] === "adb kept the phone lending").length;
    await loggedTimes("adb kept the phone lending", 2);
    out.push(await tool("adb_devices", "s1", {}), await phones("list", "work-a", "s1"), await phones("shown", "work-a"));
    // Each step done with what it set going: a grant's change connects the phone anew (adb holds it, and, held, what
    // keeps it lending), as a person would come to the next only after.
    const count = (message: string) => logged.filter((x) => x[2] === message).length;
    const settled = async <A>(f: () => Promise<A>, reconnects: number, keeps: number): Promise<A> => {
      const h = count("adb holds the phone"), k = count("adb kept the phone lending");
      const r = await f();
      await loggedTimes("adb holds the phone", h + reconnects);
      await loggedTimes("adb kept the phone lending", k + keeps);
      return r;
    };
    // A chat asks for it; the owner's app lists and decides.
    out.push(await settled(() => tool("phone_use", "s1", { reason: "debug the screen" }), 1, 2), await tool("phone_use", "s1", {}));
    out.push(await ask({ adb: { op: "grants" } }), await ask({ adb: { op: "lasts" } }));
    out.push(await settled(() => phones("use", "work-a", "s4", { ownerEmail: "Pat@Example.com" }, "kim's chat wants it"), 1, 2));
    const rowsNow = () => (side === "ts" ? w.rows() : rowsOf(file));
    out.push(await settled(() => ask({ adb: { op: "decide", request: rowsNow()[1]?.id, scope: null } }), 1, 2));
    const first = rowsNow()[0]!.id;
    out.push(await ask({ adb: { op: "sign", request: first, signed: {} } }), await ask({ adb: { op: "decide", request: "nope", scope: "hour" } }));
    out.push(await tool("phone_use", "s1", {}), await tool("adb_devices", "s1", {}), await phones("list", "work-a", "s1"), await phones("shown", "work-a"));
    out.push(await tool("phone_send", "s1", { path: "missing.apk" }));
    out.push(await ask({ adb: { op: "revoke", request: first } }, { ...PAT, email: "kim@example.com" }), await ask({ adb: { op: "revoke", request: first } }, { ...PAT, workspace: "work-b" }));
    out.push(await settled(() => ask({ adb: { op: "revoke", request: first } }), 1, 2));
    out.push(await ask({ adb: { op: "revoke", request: first } }));
    out.push(await phones("done", "work-a", "s1", null), await phones("shown", "work-a"), await tool("phone_use", "s1", { done: true }));
    // The station stops: the offer ends with it, adb not told (the next station takes the phone on as it offers again).
    if (side === "ts") await close();
    else await mbCall(id, "close");
    await offer.done;
    await m.closeAll();
    process.env.PATH = pathBefore;
    process.env.HOME = homeBefore;
    if (side === "mb") w.db = new DatabaseSync(file);
    const rows = w.rows();
    w.db.close();
    Object.assign(wall, realWall);
    // (a request's id is made of the time and chance: named by the order it came in)
    const seen: string[] = [];
    const named = JSON.stringify({ out, log, notified, cards: w.cards, wlog: w.log, rows, calls: fake.calls(), logged: [...logged] }).replace(/p_[0-9a-z]{6,}/g, (id) => {
      if (!seen.includes(id)) seen.push(id);
      return `p#${seen.indexOf(id)}`;
    });
    return normal(JSON.parse(named));
  });
});

function rowsOf(file: string): Json[] {
  const db = new DatabaseSync(file);
  try {
    return db.prepare("SELECT id,session,owner,status,body FROM adb_requests ORDER BY rowid").all().map((r) => ({ ...r }));
  } finally {
    db.close();
  }
}
