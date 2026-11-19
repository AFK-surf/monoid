// The mesh's runtime in MoonBit (station/mb src/mesh_runtime, the reader's `--builder harness-mesh-runtime`) held to the
// TypeScript it is written from (src/mesh/settings.ts, mesh.ts `applyNetwork`, native.ts `bindStation` with its DSCP,
// lan.ts, traces.ts, screen-pace.ts, screens.ts' wire and checks, lock-events.ts, reply-watch.ts, tools.ts, files.ts,
// served.ts): the same inputs given both, each answer the same; what keeps state (a view's pace, its sizer, its
// latency, the loop's stands, the traces' batches, the locks' tells, the programs told of a connection's member and the
// pieces they relay) walked through the same steps on both, on clocks of the test's, every step's answer compared. What
// of the mesh was moved before is held by mb-mesh-door.test.ts and mb-cloud-lock.test.ts.
import assert from "node:assert/strict";
import { type ChildProcess, spawn } from "node:child_process";
import { EventEmitter } from "node:events";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { rm } from "node:fs/promises";
import { type Server, type Socket, connect, createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { after, mock, test } from "node:test";
import { Effect, Exit, Scope } from "effect";
import { TestClock } from "effect/testing";
import { RUNTIME_KINDS } from "../src/agents/runtime.ts";
import { ToolError } from "../src/device/tools.ts";
import { wall } from "../src/ops/fibers.ts";
import { tr } from "../src/ops/i18n.ts";
import { log } from "../src/ops/log.ts";
import { mbReaderBinary } from "../src/read/mb-reader.ts";
import { ScreenRefused } from "../src/screens/hub.ts";
import { regionOf } from "../src/screens/source.ts";
import { fileBytes, oneBytes, readBytes, stopBytes, writeBytes } from "../src/mesh/files.ts";
import { lanAddrs, lanNeighbours, lanReach, privateV4, tailnetAddrs, tailnetV4 } from "../src/mesh/lan.ts";
import { tellLocks } from "../src/mesh/lock-events.ts";
import { Incoming, withFront } from "../src/mesh/front.ts";
import { applyNetwork } from "../src/mesh/mesh.ts";
import type { Stream } from "../src/mesh/endpoint.ts";
import { bindStation } from "../src/mesh/native.ts";
import { subOf } from "../src/mesh/person-chains.ts";
import { pathsOf, sentOn, slowly } from "../src/mesh/reply-watch.ts";
import { FrameLatency, LinkLoss, LoopStall, Pacer, Sharpener, Sizer, isFps, ownRate, queueMs, rateCeiling, startRate } from "../src/mesh/screen-pace.ts";
import {
  FrameIn, answerScreen, asked, clipPayload, configPayload, cursorPayload, frame, limitIn, parseClip, parseFill, parseInput, parseLook, parsePasskey, parseResolution, parseReveal,
  parseScale, parseWindowPick, videoPayload,
} from "../src/mesh/screens.ts";
import { SERVED_ROUTES, SERVED_STEADY_MS, Served, type ServingProcess } from "../src/mesh/served.ts";
import { checkNetwork, congestionOf, networkView } from "../src/mesh/settings.ts";
import { adminSessions, presenceTools, refusal, serveTools } from "../src/mesh/tools.ts";
import { Traces, otlpBody, parseParent, route } from "../src/mesh/traces.ts";
import { childGone } from "./child-gone.ts";

const binary = mbReaderBinary();
const skip = binary === null ? "the MoonBit program (stillfail-reader) is not built here" : false;

type Json = any;
const dirs: string[] = [];
const fresh = (prefix: string) => {
  const d = mkdtempSync(join(tmpdir(), prefix));
  dirs.push(d);
  return d;
};

/// What a test waits for of another process (the program, a client) fails `WAIT_MOST` on, saying what: never at the job's
/// limit, its sockets left open and the test's whole log lost with it, as #7002's check-station (4) was, 228 s, 2026-11-17.
const WAIT_MOST = 15_000;
async function within<A>(what: string, p: Promise<A>): Promise<A> {
  let t: ReturnType<typeof setTimeout> | undefined;
  const late = new Promise<never>((_, reject) => (t = setTimeout(() => reject(new Error(`not within ${WAIT_MOST / 1000} s: ${what}`)), WAIT_MOST)));
  try {
    return await Promise.race([p, late]);
  } finally {
    clearTimeout(t);
  }
}

/// The program, asked a line at a time.
class Program {
  #child: ChildProcess;
  #next = 0;
  #waiting = new Map<number, (v: Json) => void>();
  constructor() {
    this.#child = spawn(binary!, ["--builder", "harness-mesh-runtime", "--shell-dir", fresh("mesh-runtime-shell-")], { stdio: ["pipe", "pipe", "inherit"] });
    createInterface({ input: this.#child.stdout! }).on("line", (line) => {
      const said = JSON.parse(line);
      if (said.defect !== undefined) throw new Error(`the program failed: ${said.defect}`);
      this.#waiting.get(said.id)?.(said);
      this.#waiting.delete(said.id);
    });
  }
  ask(op: string, fields: Json = {}): Promise<Json> {
    const id = ++this.#next;
    const what = `the program's ${op}${fields.verb ? ` (${fields.verb})` : fields.fn ? ` (${fields.fn})` : ""}`;
    return within(what, new Promise<Json>((resolve) => {
      this.#waiting.set(id, resolve);
      this.#child.stdin!.write(`${JSON.stringify({ ...fields, id, op })}\n`);
    })).finally(() => this.#waiting.delete(id));
  }
  /// Its stdin ended: it ends, and is waited for (nothing of this file's is left running: setup-env.mjs).
  close(): Promise<void> {
    return childGone(this.#child);
  }
}

let program: Program | null = null;
const mb = () => (program ??= new Program());
after(async () => {
  await program?.close();
  for (const d of dirs) rmSync(d, { recursive: true, force: true });
});

/// As JSON carries it (no undefined, no -0).
const asJson = (v: unknown): Json => (v === undefined ? null : JSON.parse(JSON.stringify(v, (_k, x) => (Object.is(x, -0) ? 0 : x))));

async function answered(said: Json): Promise<Json> {
  if (said.error !== undefined) return { error: said.error };
  return asJson(said.value);
}

/// One function asked of both: the program's answer, the TypeScript's (or the words of what it threw).
async function same(fn: string, args: Json, ts: () => unknown, what = fn) {
  let theirs: Json;
  try {
    theirs = asJson(await ts());
  } catch (e) {
    theirs = { error: (e as Error).message };
  }
  const ours = await answered(await mb().ask("call", { fn, args }));
  assert.deepEqual(ours, theirs, `${what} ${JSON.stringify(args).slice(0, 300)}`);
  return ours;
}
const call = async (fn: string, args: Json = {}) => answered(await mb().ask("call", { fn, args }));
const make = async (kind: string, as: string, args: Json = {}) => answered(await mb().ask("new", { kind, as, args }));
const ask = async (on: string, method: string, args: Json = {}) => answered(await mb().ask("do", { on, method, args }));

/// A random number source of a seed's (mulberry32), so a failure is found again.
function rng(seed: number) {
  let a = seed >>> 0;
  const next = () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
  return { next, int: (n: number) => Math.floor(next() * n), pick: <T>(xs: readonly T[]) => xs[Math.floor(next() * xs.length)]! };
}

/// What the log was said, as the program says it: (level, words, with).
const logged: { level: string; at: string; words: string; with: Json }[] = [];
mock.method(log, "info", (at: string, words: string, fields?: unknown) => void logged.push({ level: "info", at, words, with: asJson(fields) }));
mock.method(log, "warn", (at: string, words: string, fields?: unknown) => void logged.push({ level: "warn", at, words, with: asJson(fields) }));
const said = (at: string) => logged.splice(0).filter((l) => l.at === at).map(({ level, words, with: w }) => ({ level, words, with: w }));

const hex = (b: Uint8Array) => Buffer.from(b).toString("hex");
const bytesOf = (h: string) => Buffer.from(h, "hex");

// ── settings, the bind's DSCP ─────────────────────────────────────────────────────────────────────────────────────

test("the network's settings and the station's bind (STILLFAIL_MESH_DSCP, #6871) as the TypeScript has them", { skip }, async () => {
  const raws: Json[] = [
    undefined, null, {}, { network: null }, { network: { congestion: "bbr" } }, { network: { congestion: "cubic" } }, { network: { congestion: "BBR" } },
    { network: "bbr" }, { network: [] }, [], 7, "x",
  ];
  for (const raw of raws) {
    const args = raw === undefined ? {} : { raw };
    await same("congestionOf", args, () => congestionOf(raw));
    await same("networkView", args, () => networkView(raw));
  }
  const networks: Json[] = [undefined, null, {}, { congestion: "bbr" }, { congestion: "cubic" }, { congestion: null }, { congestion: "x" }, [], "bbr", 3, true, { other: 1 }];
  for (const raw of networks) {
    await same("checkNetwork", raw === undefined ? {} : { raw }, () => {
      checkNetwork(raw);
      return { ok: true };
    });
  }
  const bound = async (options: Json, env: Record<string, string>) => {
    let given: Json = null;
    await bindStation({ bind: async (o) => ((given = o), {} as never) }, options, env);
    return given;
  };
  const options = { alpns: ["a"], relayUrls: ["https://r"], congestion: "bbr", bindAddr: "1.2.3.4:5" };
  for (const dscp of [undefined, "43", "1", "63", "0", "64", "999", "007", "1000", "", " 43", "4x", "-1", "1.5", "0x2b", "٤٣", "\u0000", "\"quoted\""]) {
    for (const addr of [undefined, "0.0.0.0:7777"]) {
      const env: Record<string, string> = {};
      if (dscp !== undefined) env.STILLFAIL_MESH_DSCP = dscp;
      if (addr !== undefined) env.STILLFAIL_MESH_BIND_ADDR = addr;
      await same("bindStation", { options, ...(addr !== undefined ? { bindAddr: addr } : {}), ...(dscp !== undefined ? { dscp } : {}) }, () => bound(options, env), `bindStation ${dscp}`);
    }
  }
});

test("a running endpoint follows the config's congestion controller, as applyNetwork does", { skip }, async () => {
  for (const fails of [false, true]) {
    const name = `follow-${fails}`;
    let listener: (raw: Json) => void = () => {};
    const calls: Json[] = [];
    let raw: Json = { network: { congestion: "cubic" } };
    applyNetwork(
      { setCongestion: (c) => {
        calls.push({ set: c });
        if (fails) throw new Error("not now");
      } },
      { raw: () => raw, listen: (f) => ((listener = f), () => {}) },
    );
    await make("NetworkFollow", name, { raw });
    await ask(name, "fails", { fails });
    for (const next of [{ network: { congestion: "bbr" } }, { network: { congestion: "bbr" } }, {}, null, { network: { congestion: "bbr" } }, { network: { congestion: "cubic" } }]) {
      raw = next;
      logged.length = 0;
      listener(next);
      for (const l of said("mesh")) calls.push(l);
      await ask(name, "told", { raw: next });
    }
    assert.deepEqual(await ask(name, "calls"), asJson(calls));
  }
});

// ── the LAN ───────────────────────────────────────────────────────────────────────────────────────────────────────

test("a station's LAN and tailnet addresses, its neighbours and whether it may reach them, as lan.ts has them", { skip }, async () => {
  for (const ip of [
    "10.0.0.1", "10.255.255.255", "172.16.0.1", "172.31.255.1", "172.32.0.1", "172.15.0.1", "192.168.1.1", "192.169.1.1", "8.8.8.8", "100.64.0.1", "100.127.255.255",
    "100.128.0.1", "100.63.0.1", "10.0.0", "10.0.0.1.2", "10..0.1", "10.0.0.256", "10.0.0.-1", "10.0.0.1e0", " 10.0.0.1", "10.0.0.0x1", "10.0.0.1.", "", "a.b.c.d", "010.0.0.1",
    "100.0x40.0.1", "1e1.0.0.1", "10.0.0.+1", "10.0.0. 1", "192.168.1.1\n",
  ]) {
    await same("privateV4", { ip }, () => privateV4(ip));
    await same("tailnetV4", { ip }, () => tailnetV4(ip));
  }
  const iface = (address: string, netmask: string, family = "IPv4", internal = false) => ({ address, netmask, family, internal, mac: "00:00:00:00:00:00", cidr: null });
  const worlds: Json[] = [
    {},
    { lo0: [iface("127.0.0.1", "255.0.0.0", "IPv4", true)], en0: [iface("192.168.1.23", "255.255.255.0"), iface("fe80::1", "ffff::", "IPv6")] },
    { en0: [iface("192.168.1.1", "255.255.255.0")], en1: [iface("10.1.2.3", "255.255.0.0")], utun3: [iface("100.101.102.103", "255.255.255.255")] },
    { bridge100: [iface("192.168.64.1", "255.255.255.0")], vmnet8: [iface("172.16.5.1", "255.255.255.0")], ap1: [iface("10.0.0.5", "255.0.0.0")], ap: [iface("10.9.9.9", "255.255.255.0")] },
    { eth0: [iface("172.20.0.7", "255.255.240.0"), iface("172.20.0.7", "255.255.240.0")], tailscale0: [iface("100.64.0.9", "255.192.0.0")], docker0: [iface("172.17.0.1", "255.255.0.0")] },
    { wlan0: [iface("192.168.0.0", "255.255.255.0"), iface("192.168.0.1", "255.255.255.255"), iface("10.0.0.1", "")], llw0: [iface("10.0.0.2", "255.0.0.0")] },
    { en5: [iface("192.168.255.255", "255.255.255.254"), iface("10.255.255.254", "255.255.255.252"), iface("172.16.0.1", "0.0.0.0")] },
  ];
  const socketSets = [["0.0.0.0:7777", "[::]:7777"], ["[::]:7777", "192.168.1.23:4444"], ["10.1.2.3:9", "0.0.0.0:7"], ["[::]:1"], [], ["192.168.1.1:80x"], ["1.2.3:4"]];
  for (const interfaces of worlds) {
    for (const sockets of socketSets) {
      await same("lanAddrs", { sockets, interfaces }, () => lanAddrs(sockets, interfaces));
      await same("tailnetAddrs", { sockets, interfaces }, () => tailnetAddrs(sockets, interfaces));
    }
    await same("lanNeighbours", { interfaces }, () => lanNeighbours(interfaces));
  }
  const reaches: [string[], Record<string, string | null>][] = [
    [[], {}], [["192.168.1.1"], { "192.168.1.1": null }], [["192.168.1.1"], { "192.168.1.1": "EHOSTUNREACH" }],
    [["192.168.1.1", "10.0.0.1"], { "192.168.1.1": "EHOSTUNREACH", "10.0.0.1": null }], [["192.168.1.1", "10.0.0.1"], { "192.168.1.1": "EHOSTUNREACH", "10.0.0.1": "ENETUNREACH" }],
    [["192.168.1.1", "10.0.0.1"], { "192.168.1.1": "EHOSTUNREACH", "10.0.0.1": "EHOSTUNREACH" }], [["10.0.0.1"], { "10.0.0.1": "error" }],
  ];
  for (const [neighbours, codes] of reaches) {
    await same("lanReach", { neighbours, codes }, () => lanReach(neighbours, async (ip) => codes[ip] ?? null));
  }
});

// ── traces ────────────────────────────────────────────────────────────────────────────────────────────────────────

test("a traceparent, a route without its ids and an OTLP batch, as traces.ts has them", { skip }, async () => {
  const T = "4bf92f3577b34da6a3ce929d0e0e4736", S = "00f067aa0ba902b7";
  for (const header of [
    undefined, "", `00-${T}-${S}-01`, `00-${T}-${S}-00`, `00-${T}-${S}-03`, `  00-${T}-${S}-01\n`, ` 00-${T}-${S}-01 `, `ff-${T}-${S}-01`, `zz-${T}-${S}-01`, `0-${T}-${S}-01`,
    `00-${T.toUpperCase()}-${S.toUpperCase()}-0A`, `00-${"0".repeat(32)}-${S}-01`, `00-${T}-${"0".repeat(16)}-01`, `00-${T}-${S}-1`, `00-${T}-${S}-0g`, `00-${T}-${S}-01-x`, `00-${T}x-${S}-01`, `00-${T}-${S}`,
  ]) {
    await same("parseParent", header === undefined ? {} : { header }, () => parseParent(header));
  }
  for (const path of [
    "/admin/api/threads/42/messages?limit=50", "/admin/api/sessions/slack:T1:C1/files?name=a.pdf", "/", "", "/admin/api/stations/abc/members/x", "/admin/api/a_b-c.d#frag",
    "/admin/api/UPPER/x", "/admin/api/aaaaaaaaaaaaaaaaaaaaaaaaa", "/admin/api/aaaaaaaaaaaaaaaaaaaaaaaa", "//double//slash", "/admin/api/12345", "/admin/api/v2", "/a?b#c/d", "/admin/api/jobs/x/log",
    "/admin/api/workspaces/w1/members/m1/devices", "/admin/api/threads/42?x=/threads/9", "/admin/api/日本",
  ]) {
    await same("route", { path }, () => route(path));
  }
  const spans = [{ a: 1 }, { traceId: "x", attributes: [], nested: { "2": 1, b: [1, 2.5, null, "s"] } }];
  for (const station of ["s1", "", "名字 \"q\""]) await same("otlpBody", { station, spans }, () => otlpBody(station, spans));
});

test("the traces' spans and their batches, on the clocks of the test's", { skip }, async () => {
  let HR = 10n;
  let WALL = 1_000;
  const hrtime = mock.method(process.hrtime, "bigint", () => HR);
  const now = mock.method(wall, "now", () => WALL);
  const scope = Effect.runSync(Scope.make());
  const clock = Effect.runSync(Scope.provide(TestClock.make(), scope));
  const turns = async () => {
    for (let i = 0; i < 6; i++) await new Promise<void>((r) => setImmediate(r));
  };
  try {
    for (const enabled of [false, true]) {
      const name = `traces-${enabled}`;
      const traces = new Traces(enabled, { clock });
      await make("Traces", name, { enabled });
      const sent: unknown[][] = [];
      let failing = 0;
      traces.exportTo(async (batch) => {
        if (failing > 0) {
          failing--;
          throw new Error("the plane is down");
        }
        sent.push(batch);
      });
      await ask(name, "export");
      const parents = [
        parseParent("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"), parseParent("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-00"), null,
      ];
      const r = rng(7);
      let k = 0;
      for (let round = 0; round < 4; round++) {
        if (round === 2) {
          failing = 1;
          await ask(name, "fail", { times: 1 });
        }
        // more than a batch's worth, and some with nothing recorded
        const n = round === 1 ? 6_500 : 30;
        for (let i = 0; i < n; i++) {
          const parent = r.pick(parents);
          WALL += r.int(5);
          HR += BigInt(r.int(2_000_000));
          await mb().ask("hr", { ns: Number(HR) });
          const span = traces.start(parent);
          const ours = await ask(name, "start", { parent: asJson(parent), spanId: span?.id ?? "", wallMs: WALL, as: `s${k}` });
          assert.equal(ours, span === null ? null : Traces.traceparent(span));
          if (span === null) continue;
          HR += BigInt(r.int(90_000_000));
          await mb().ask("hr", { ns: Number(HR) });
          const attributes: [string, unknown][] = [["http.response.status_code", r.pick([200, 404, 1.5, -0.25, 1e21])], ["ok", r.next() < 0.5], ["route", "/a"], ["x", { a: [1] }], ["n", null]];
          const failed = r.next() < 0.3;
          traces.end(span, `GET /r${i}`, attributes, failed);
          await ask(name, "end", { span: `s${k++}`, name: `GET /r${i}`, attributes, failed });
        }
        assert.deepEqual(await ask(name, "spans"), asJson(traces.spans), `spans of round ${round}`);
        logged.length = 0;
        await Effect.runPromise(clock.adjust(3_000));
        await turns();
        await mb().ask("advance", { ms: 3_000 });
        assert.deepEqual(await ask(name, "sent"), asJson(sent), `batches of round ${round}`);
        assert.deepEqual(await ask(name, "said"), said("telemetry"), `said of round ${round}`);
        assert.deepEqual(await ask(name, "spans"), asJson(traces.spans));
      }
      await traces.close();
      await ask(name, "close");
    }
  } finally {
    hrtime.mock.restore();
    now.mock.restore();
    await Effect.runPromise(Scope.close(scope, Exit.void));
  }
});

// ── a screen's pace ───────────────────────────────────────────────────────────────────────────────────────────────

test("what a view's pace asks, as screen-pace.ts's functions have it", { skip }, async () => {
  for (const [width, height] of [[0, 0], [640, 480], [1920, 1080], [3840, 2160], [8192, 8192], [333.5, 10], [1, 1e9]]) {
    await same("ownRate", { width, height }, () => ownRate(width!, height!));
    for (const quality of [undefined, "smooth", "hd", "original"] as const) {
      await same("rateCeiling", { width, height, ...(quality ? { quality } : {}) }, () => rateCeiling(width!, height!, quality));
    }
  }
  for (const v of [120, 90, 60, 30, 15, 0, 24, "60", null, 60.0000001, true]) await same("isFps", { v }, () => isFps(v));
  for (const rtt of [0, 10, 59, 60, 61, 300.5]) await same("queueMs", { rtt }, () => queueMs(rtt));
  const way = (o: Json) => ({ selected: true, relay: null, ip: "10.0.0.2:7000", rttMs: 5, txPackets: 1, lostPackets: 0, ...o });
  const ways: Json[] = [
    [], [way({})], [way({ rttMs: 12 })], [way({ rttMs: 12.0001 })], [way({ rttMs: 40 })], [way({ rttMs: 41 })], [way({ rttMs: 100 })], [way({ rttMs: 100.5 })],
    [way({ rttMs: null })], [way({ rttMs: 0 })], [way({ rttMs: -3 })], [way({ rttMs: "5" })], [way({ ip: "" })], [way({ ip: null })], [way({ relay: "" })],
    [way({ relay: "https://r/", ip: null, rttMs: 35 })], [way({ relay: "https://r/", ip: null, rttMs: 35.5 })], [way({ relay: "https://r/", rttMs: 3 })], [way({ relay: "https://r/", rttMs: null })],
    [way({ selected: false, rttMs: 3 }), way({ selected: false, relay: "https://r/", rttMs: 200 })], [way({ selected: false, relay: "https://r/", rttMs: 20 }), way({ selected: false, rttMs: 30 })],
    [way({ selected: false, relay: "https://r/", ip: null, rttMs: 20 }), way({ selected: false, relay: "https://r2/", ip: null })], [way({ selected: false, rttMs: 3 }), way({ relay: "https://r/", rttMs: 200 })],
  ];
  await same("startRate", {}, () => startRate());
  for (const paths of ways) await same("startRate", { paths }, () => startRate(paths));
  const cursors: Json[] = [null, { x: 0.25, y: 0.5, shape: "text" }, { x: 0.123456, y: 0.987654 }, { x: -1, y: 2, shape: "" }, { x: 1, y: 0, shape: "x".repeat(64) }, { x: 1, y: 0, shape: "x".repeat(65) }, { x: 0.5, y: 0.5, shape: "é中".repeat(10) }, { x: 0.99999, y: 0.000007 }, { y: 0.5 }];
  for (const cursor of cursors) await same("cursorPayload", { cursor }, () => hex(cursorPayload(cursor)));
});

/// The pace's things walked through random steps on both, each answer compared.
test("a view's pacer, sizer, sharpener and frame latency, step for step, on a random link", { skip }, async () => {
  for (let seed = 1; seed <= 12; seed++) {
    const r = rng(seed);
    let NOW = 1000 + r.int(1e6);
    let STALL = 0;
    const clock = async () => {
      await mb().ask("now", { ms: NOW });
      await mb().ask("stalled", { ms: STALL });
    };
    await clock();
    const start = r.pick([null, 1_500_000, 300_000]);
    const fps = r.pick([undefined, 60, 30, 120, 15]);
    const pacer = new Pacer(() => NOW, start, fps, () => STALL);
    const p = `pacer-${seed}`;
    await make("Pacer", p, { ...(start !== null ? { start } : {}), ...(fps !== undefined ? { fps } : {}) });
    const quality = r.pick([undefined, "smooth", "hd", "original"] as const);
    const bounds = r.pick([{ maxWidth: 1920, maxHeight: 1080 }, { maxWidth: 1280, maxHeight: 720 }, { maxWidth: 3840, maxHeight: 2160 }]);
    const sizer = new Sizer(() => NOW, bounds, quality);
    const z = `sizer-${seed}`;
    await make("Sizer", z, { asked: bounds, ...(quality ? { quality } : {}) });
    const sharpen = new Sharpener();
    const h = `sharpen-${seed}`;
    await make("Sharpener", h);
    const latency = new FrameLatency(() => NOW);
    const l = `latency-${seed}`;
    await make("FrameLatency", l);
    // the link: a round trip and a rate, changing as it goes
    let rtt = r.pick([2, 20, 80, 250]);
    let ts = 0;
    const out: { ts: number; at: number; bytes: number }[] = [];
    let width = 1920, height = 1080;
    for (let step = 0; step < 500; step++) {
      const what = r.int(14);
      NOW += r.pick([0, 1, 3, 8, 16, 33, 50, 120, 400, 1500]) + r.next();
      if (r.next() < 0.05) STALL += r.int(140);
      if (r.next() < 0.03) rtt = r.pick([2, 20, 80, 250, 900]);
      await clock();
      const step_ = `seed ${seed} step ${step}`;
      switch (what) {
        case 0: case 1: case 2: {
          const may = pacer.may();
          assert.equal(await ask(p, "may"), may, `${step_} may`);
          if (may) {
            ts += r.int(40_000) + 1;
            const bytes = r.pick([800, 20_000, 120_000, 600_000]) + r.int(1000);
            pacer.sent(ts, bytes);
            await ask(p, "sent", { ts, bytes });
            out.push({ ts, at: NOW, bytes });
            const capture = (NOW - r.int(80)) * 1000;
            latency.sent(capture);
            await ask(l, "sent", { ts: capture });
            const rate = r.next() < 0.2 ? null : pacer.rate();
            const key = r.next() < 0.1;
            sharpen.sent(NOW, rate, key);
            await ask(h, "sent", { now: NOW, ...(rate !== null ? { rate } : {}), key });
          }
          break;
        }
        case 3: case 4: case 5: {
          const due = out.filter((f) => f.at + rtt <= NOW);
          if (due.length === 0) break;
          const upTo = due[r.int(due.length)]!.ts;
          pacer.acked(upTo);
          await ask(p, "acked", { ts: upTo });
          out.splice(0, out.findIndex((f) => f.ts === upTo) + 1);
          const trip = pacer.rtt() ?? 0;
          latency.acked(upTo * 1000, trip);
          await ask(l, "acked", { ts: upTo * 1000, rtt: trip });
          break;
        }
        case 6: {
          const rate = r.pick([ownRate(width, height), 4_000_000, 900_000]);
          pacer.ceiling(rate);
          await ask(p, "ceiling", { rate });
          break;
        }
        case 7:
          if (r.next() < 0.2) {
            width = r.pick([1920, 1280, 2560, 800]);
            height = r.pick([1080, 720, 1440, 600]);
          }
          {
            const rate = pacer.rate() ?? 1_500_000;
            const through = pacer.through();
            const ours = await ask(z, "step", { rate, through, width, height });
            assert.deepEqual(ours, asJson(sizer.step(rate, through, { width, height })), `${step_} step`);
          }
          break;
        case 8:
          if (r.next() < 0.1) {
            const b = r.pick([{ maxWidth: 800, maxHeight: 600 }, { maxWidth: 4000, maxHeight: 3000 }, bounds]);
            assert.deepEqual(await ask(z, "ask", { asked: b }), asJson(sizer.ask(b)), `${step_} ask`);
          }
          break;
        case 9:
          assert.deepEqual(await ask(l, "take"), asJson(latency.take()), `${step_} take`);
          break;
        case 10: {
          const rate = r.pick([null, pacer.rate(), 5_000_000]);
          assert.equal(await ask(h, "left", { now: NOW }), sharpen.left(NOW), `${step_} left`);
          assert.equal(await ask(h, "due", { now: NOW, ...(rate !== null ? { rate } : {}) }), sharpen.due(NOW, rate), `${step_} due`);
          const moving = r.pick([null, pacer.rate(), 5_000_000, 40_000_000]);
          assert.equal(await ask(h, "dueMoving", { now: NOW, ...(moving !== null ? { rate: moving } : {}) }), sharpen.dueMoving(NOW, moving), `${step_} dueMoving`);
          break;
        }
        default:
          break;
      }
      assert.equal(await ask(p, "backlogged"), pacer.backlogged(), `${step_} backlogged`);
      assert.equal(await ask(p, "rate"), pacer.rate(), `${step_} rate`);
      assert.equal(await ask(p, "through"), pacer.through(), `${step_} through`);
      assert.equal(await ask(p, "rtt"), pacer.rtt(), `${step_} rtt`);
      assert.equal(await ask(p, "wait"), pacer.wait(), `${step_} wait`);
      assert.equal(await ask(p, "unacked"), pacer.unacked, `${step_} unacked`);
      assert.deepEqual(await ask(z, "bounds"), asJson(sizer.bounds()), `${step_} bounds`);
      assert.deepEqual(await ask(z, "asked"), asJson(sizer.asked), `${step_} asked`);
      assert.equal(await ask(z, "low"), sizer.low, `${step_} low`);
    }
  }
});

test("what of a view's link was lost, step for step, as LinkLoss counts it", { skip }, async () => {
  for (let seed = 1; seed <= 6; seed++) {
    const r = rng(300 + seed);
    let NOW = r.int(1e6);
    const loss = new LinkLoss(() => NOW);
    const name = `loss-${seed}`;
    await mb().ask("now", { ms: NOW });
    await make("LinkLoss", name);
    let tx = 0, lost = 0;
    let key = "a";
    for (let step = 0; step < 400; step++) {
      NOW += r.pick([0, 10, 1000, 1000, 1000, 30_000, 61_000]);
      await mb().ask("now", { ms: NOW });
      const what = r.int(10);
      if (what < 6) {
        tx += r.pick([0, 1, 5, 40, 400]);
        lost += r.pick([0, 0, 0, 1, 3, 30]);
      } else if (what === 6) key = r.pick(["a", "b"]);
      else if (what === 7) tx = Math.max(0, tx - 10);
      const way = { ...(r.next() < 0.5 ? { id: key } : { relay: `https://${key}/` }), selected: true, ip: "1.2.3.4:5", txPackets: tx, lostPackets: lost };
      const paths = what === 8 ? [] : what === 9 ? [{ ...way, selected: false }] : [{ selected: false, relay: "x", txPackets: 9, lostPackets: 9 }, way];
      const verb = r.next() < 0.7 ? "step" : "sample";
      assert.equal(await ask(name, verb, { paths }), verb === "step" ? loss.step(paths) : loss.sample(paths), `seed ${seed} step ${step}`);
    }
  }
});

test("how long the loop stood still, counted while views use it, as LoopStall has it", { skip }, async () => {
  let NOW = 5_000;
  const ticking: { tick: (() => void) | null } = { tick: null };
  const every = mock.method(wall, "every", (_ms: number, f: () => void) => {
    ticking.tick = f;
    return () => void (ticking.tick = null);
  });
  try {
    const stall = new LoopStall(() => NOW);
    await make("LoopStall", "stall");
    const uses = new Map<string, { done: () => void }>();
    const r = rng(3);
    for (let step = 0; step < 300; step++) {
      NOW += r.pick([0, 5, 10, 11, 40, 140]) + r.next();
      await mb().ask("now", { ms: NOW });
      const what = r.int(5);
      const as = `u${r.int(3)}`;
      if (what === 0) {
        uses.set(as, stall.use());
        await ask("stall", "use", { as });
      } else if (what === 1) {
        uses.get(as)?.done();
        await ask("stall", "done", { as });
      } else if (what === 2) {
        const was: boolean = ticking.tick !== null;
        ticking.tick?.();
        assert.equal(await ask("stall", "tick"), was, `step ${step} ticking`);
      }
      assert.equal(await ask("stall", "stalled"), stall.stalled(), `step ${step} stalled`);
      assert.equal(await ask("stall", "ticking"), ticking.tick !== null, `step ${step} ticking`);
    }
  } finally {
    every.mock.restore();
  }
});

// ── a screen's wire ───────────────────────────────────────────────────────────────────────────────────────────────

test("a view's frames, its ask and every frame a client sends, checked as screens.ts checks them", { skip }, async () => {
  for (const [kind, payload] of [[1, ""], [2, "00ff"], [255, "ab".repeat(70_000)]] as const) {
    await same("frame", { kind, payload }, () => hex(frame(kind, bytesOf(payload))));
  }
  const regions = [undefined, { x: 0.1, y: 0.2, w: 0.5, h: 0.25 }, { x: 0.3333333, y: 0, w: 1, h: 0.5 }];
  for (const region of regions) {
    for (const description of [undefined, "", "0102ff"]) {
      for (const codec of ["h264", "jpeg"]) {
        const c = { codec, width: 1920, height: 1080.5, ...(description !== undefined ? { description } : {}), ...(region ? { region } : {}) };
        await same("configPayload", { config: c }, () =>
          hex(configPayload({ codec: codec as "h264", width: 1920, height: 1080.5, ...(description !== undefined ? { description: bytesOf(description) } : {}), ...(region ? { region } : {}) })));
      }
    }
  }
  for (const ts of [0, -5, 1.9, 1e15 + 0.5, 123456789]) {
    for (const key of [true, false]) {
      await same("videoPayload", { frame: { key, ts, data: "abcd" } }, () => hex(videoPayload({ key, ts, data: bytesOf("abcd") } as never)));
    }
  }
  const clips: Json[] = [{ type: "text", text: "héllo 😀" }, { type: "text", text: "" }, { type: "png", data: "89504e47" }, { type: "png", data: "" }];
  for (const clip of clips) {
    for (const flags of [undefined, 0, 1, 3]) {
      const tsClip = clip.type === "text" ? clip : { type: "png", data: new Uint8Array(bytesOf(clip.data)) };
      await same("clipPayload", { clip, ...(flags !== undefined ? { flags } : {}) }, () => hex(clipPayload(tsClip, flags)));
    }
  }
  const clipJson = (c: ReturnType<typeof parseClip>) => (c === null ? null : { clip: c.clip.type === "text" ? c.clip : { type: "png", data: hex(c.clip.data) }, paste: c.paste });
  for (const payload of ["", "0001", "000141", "010141", "0301c3a9", "0002ff", "000300", "0001ff", "0001efbbbf41", "01020000"]) {
    await same("parseClip", { payload }, () => clipJson(parseClip(bytesOf(payload))));
  }
  const big = "00" + "01" + "41".repeat(1024 * 1024 + 1);
  await same("parseClip", { payload: big }, () => clipJson(parseClip(bytesOf(big))), "parseClip of a clip too large");
  const inputs: Json[] = [
    null, 1, "x", [], {}, { t: "scale", percent: 100 }, { t: "scale", percent: 99 }, { t: "scale", percent: 500 }, { t: "scale", percent: 250.5 }, { t: "scale", percent: "200" },
    { t: "resolution", width: 640, height: 16384 }, { t: "resolution", width: 639, height: 700 }, { t: "resolution", width: 1920.5, height: 1080 },
    { t: "reveal", path: "/a/b" }, { t: "reveal", path: "" }, { t: "reveal", path: "x".repeat(4097) }, { t: "reveal", path: "😀".repeat(2048) }, { t: "reveal", path: "😀".repeat(2049) },
    { t: "fill", host: "a.com", username: "u" }, { t: "fill", host: "a.com" }, { t: "fill", host: "a.com", password: "p", username: 3 }, { t: "fill", host: "", password: "p" },
    { t: "fill", host: "h".repeat(254), password: "p" }, { t: "fill", host: "a.com", password: "p".repeat(1025) }, { t: "fill", host: "a.com", username: "", password: "" },
    { t: "passkey", id: "abc", error: "NotAllowedError" }, { t: "passkey", id: "abc", error: "Not Allowed" }, { t: "passkey", id: "abc", error: "" }, { t: "passkey", id: "abc", error: 3 },
    { t: "passkey", id: "abc", credential: "Q-_", authenticatorData: "AA", signature: "BB" }, { t: "passkey", id: "abc", credential: "Q=", authenticatorData: "AA", signature: "BB" },
    { t: "passkey", id: "abc", credential: "Q", authenticatorData: "AA", signature: "BB", userHandle: "u", clientData: "c" }, { t: "passkey", id: "", credential: "Q", authenticatorData: "A", signature: "B" },
    { t: "passkey", id: "x".repeat(33), credential: "Q", authenticatorData: "A", signature: "B" }, { t: "passkey", id: "abc", credential: "Q", authenticatorData: "A", signature: "B", userHandle: "" },
    { t: "window", id: 5 }, { t: "window" }, { t: "window", id: null }, { t: "window", id: 0 }, { t: "window", id: 4294967296 }, { t: "window", id: 4294967295 }, { t: "window", id: 1.5 },
    { t: "pointer", kind: "down", x: 0.5, y: 2, buttons: 15 }, { t: "pointer", kind: "move", x: -1, y: 0.3 }, { t: "pointer", kind: "drag", x: 0, y: 0 }, { t: "pointer", kind: "up", x: "1", y: 0 },
    { t: "pointer", kind: "up", x: 0, y: 0, buttons: -1 }, { t: "pointer", kind: "up", x: 0, y: 0, buttons: 2.9 }, { t: "pointer", kind: "up", x: 0, y: 0, buttons: 4294967303 },
    { t: "wheel", x: 0.5, y: 0.5, dx: 20_000, dy: -20_000 }, { t: "wheel", x: 0.5, y: 0.5, dx: 1 }, { t: "key", kind: "down", key: "a", code: "KeyA", mods: 31 },
    { t: "key", kind: "press", key: "a", code: "KeyA" }, { t: "key", kind: "up", key: "a".repeat(65), code: "KeyA" }, { t: "key", kind: "up", key: "a", code: "KeyA", mods: 1.5 },
    { t: "text", text: "hi" }, { t: "text", text: "" }, { t: "text", text: "x".repeat(4097) }, { t: "pose", name: "book" }, { t: "pose", name: "flat" }, { t: "device", name: "rotate" },
    { t: "device", name: "shake" }, { t: "button", page: 12, usage: 64, down: true }, { t: "button", page: 0, usage: 64, down: true }, { t: "button", page: 12, usage: 65536, down: false },
    { t: "button", page: 12, usage: 64, down: 1 }, { t: "other" },
  ];
  for (const v of inputs) {
    await same("parseScale", { v }, () => parseScale(v));
    await same("parseResolution", { v }, () => parseResolution(v));
    await same("parseReveal", { v }, () => parseReveal(v));
    await same("parseFill", { v }, () => parseFill(v));
    await same("parsePasskey", { v }, () => parsePasskey(v));
    await same("parseWindowPick", { v }, () => {
      const pick = parseWindowPick(v);
      return pick === undefined ? "undefined" : pick;
    });
    await same("parseInput", { v }, () => parseInput(v));
  }
  const own = { maxWidth: 1920, maxHeight: 1080 };
  const looks = [
    "", "{", "null", "[]", "3", "{}", JSON.stringify({ region: { x: 0.1, y: 0.1, w: 0.5, h: 0.5 }, maxWidth: 800.4, maxHeight: 10 }), JSON.stringify({ region: { x: 0, y: 0, w: 1, h: 1 } }),
    JSON.stringify({ region: { x: 0.9, y: -1, w: 0.001, h: 0.5 }, maxWidth: 99999 }), JSON.stringify({ region: { x: 0.5, y: 0.5, w: 0.99, h: 0.5 }, maxWidth: "800" }),
    JSON.stringify({ region: { x: 1, y: 1, w: 0.3333333, h: 0.66666666 } }), JSON.stringify({ region: [1, 2, 3, 4] }), "﻿{}",
  ];
  for (const text of looks) {
    const payload = Buffer.from(text, "utf8").toString("hex");
    await same("parseLook", { payload, own }, () => parseLook(bytesOf(payload), own));
  }
  for (const v of [undefined, null, { x: 0, y: 0, w: 0.5, h: 0.5 }, { x: 0.12345678, y: 0.5, w: 0.98, h: 0.97 }, { x: 0, y: 0, w: 0.98, h: 0.98 }, { x: Number.MAX_VALUE, y: 0, w: 2, h: 0.1 }, { x: 0, y: 0, w: 0.5 }]) {
    await same("regionOf", v === undefined ? {} : { v }, () => regionOf(v));
  }
  const screens: Json[] = [
    {}, { codecs: ["h264", "vp9", "h265"], maxWidth: 99999, maxHeight: 3.4, control: true, fit: { width: 390, height: 844, scale: 3 }, quality: "hd", fps: 60, audio: "pcm_s16le", opus: true, passkeys: false },
    { codecs: ["jpeg"], control: true, passkeys: true }, { codecs: ["jpeg"], peek: true, passkeys: false }, { codecs: ["jpeg"], passkeys: "yes" },
    { codecs: "h264", peek: true, control: true, quality: "smooth", fps: 30, audio: "pcm_s16le", gamut: "p3", client: "  iPhone\u0000​ 15  ", app: "x".repeat(40), self: "‮dev", taken: true },
    { control: true, fit: { width: 100, height: 844, scale: 3 } }, { control: false, fit: { width: 390, height: 844, scale: 3 } }, { control: true, fit: { width: 390.6, height: 2000, scale: 4.5 } },
    { codecs: ["jpeg", "jpeg"], fps: 24, quality: "best", gamut: "srgb", client: 5, app: "", self: "😀".repeat(40), taken: "yes", maxWidth: -3, maxHeight: Number.NaN },
    { client: "\u{e0001}tag\u{e0020}", app: "­؀x", maxWidth: 1919.5, maxHeight: 1080.49 },
    { codecs: ["h264"], binaryCursor: true, taken: true }, { codecs: ["h264"], binaryCursor: true, peek: true }, { codecs: ["h264"], binaryCursor: 1 }, { codecs: ["h264"], binaryCursor: false },
    { codecs: ["h264"], datagrams: 77 }, { codecs: ["h264"], datagrams: 4294967295 }, { codecs: ["h264"], datagrams: 77, peek: true }, { codecs: ["h264"], datagrams: 0 },
    { codecs: ["h264"], datagrams: 1.5 }, { codecs: ["h264"], datagrams: 4294967296 }, { codecs: ["h264"], datagrams: "77" },
  ];
  for (const screen of screens) await same("asked", { screen }, () => asked(screen));
  for (const kind of [16, 19, 20]) await same("limitIn", { kind }, () => limitIn(kind));
});

test("frames read from a stream, after what came with its head, as FrameIn reads them", { skip }, async () => {
  const f = (kind: number, payload: string) => hex(frame(kind, bytesOf(payload)));
  const cases: { carry: string; chunks: string[]; limit?: number }[] = [
    { carry: "", chunks: [] },
    { carry: f(16, "7b7d"), chunks: [] },
    { carry: f(16, "7b7d").slice(0, 6), chunks: [f(16, "7b7d").slice(6), f(17, "")] },
    { carry: "", chunks: [f(19, "00").slice(0, 4), f(19, "00").slice(4) + f(20, "ab"), "10"] },
    { carry: "", chunks: [hex(Buffer.from([16, 0, 1, 0, 1]))] },
    { carry: "", chunks: [hex(Buffer.from([19, 0, 1, 0, 1]))] },
    { carry: "", chunks: [f(16, "aabbcc")], limit: 2 },
    { carry: "", chunks: [hex(Buffer.from([16, 0xff, 0xff, 0xff, 0xff]))] },
    { carry: "1000", chunks: ["0000", "01"] },
  ];
  for (const c of cases) {
    await same("frameIn", c, async () => {
      let at = 0;
      const stream = { read: async () => (at < c.chunks.length ? bytesOf(c.chunks[at++]!) : null) } as never;
      const frames = new FrameIn(stream, bytesOf(c.carry), c.limit ?? limitIn);
      const out: Json[] = [];
      for (;;) {
        try {
          const next = await frames.next();
          if (next === null) break;
          out.push({ kind: next.kind, payload: hex(next.payload) });
        } catch (e) {
          out.push({ error: (e as Error).message });
          break;
        }
      }
      return out;
    });
  }
});

// ── the locks' tells ──────────────────────────────────────────────────────────────────────────────────────────────

test("what a station tells its devices of the locks, step for step, as lock-events.ts tells it", { skip }, async () => {
  const r = rng(11);
  const world = { memberships: [] as { workspace: string; home: boolean }[], heads: {} as Record<string, Json>, forces: {} as Record<string, string>, chains: {} as Record<string, Json[]> };
  let cloudListener: () => void = () => {};
  let chainListener: (genesis: string) => void = () => {};
  const cloud = {
    memberships: () => world.memberships,
    chain: (ws: string | null) => {
      const h = world.heads[ws ?? ""];
      return h === undefined ? null : { state: { seq: h.seq, head: h.hash, genesis: h.genesis } };
    },
    forceWord: (ws: string | null) => world.forces[ws ?? ""] ?? "",
    listen: (f: () => void) => ((cloudListener = f), () => (cloudListener = () => {})),
  };
  const chains = {
    listen: (f: (g: string) => void) => ((chainListener = f), () => (chainListener = () => {})),
    kept: (g: string) => world.chains[g] ?? null,
  };
  const told: Json[] = [];
  const set = async (change: Json) => {
    if (change.memberships) world.memberships = change.memberships;
    for (const [k, v] of Object.entries(change.heads ?? {})) {
      if (v === null) delete world.heads[k];
      else world.heads[k] = v;
    }
    Object.assign(world.forces, change.forces ?? {});
    for (const [k, v] of Object.entries(change.chains ?? {})) {
      if (v === null) delete world.chains[k];
      else world.chains[k] = v as Json[];
    }
  };
  const first = { memberships: [{ workspace: "home-ws", home: true }, { workspace: "w1", home: false }], heads: { "": { seq: 1, hash: "h1", genesis: "g" }, w1: { seq: 4, hash: "x4", genesis: "g1" } }, forces: { w1: "f0" } };
  await set(first);
  const stop = tellLocks(cloud as never, chains as never, (event, data, of, to) => void told.push({ event, data, of, to }));
  await make("LockTells", "tells", first);
  for (let step = 0; step < 200; step++) {
    const change: Json = {};
    const what = r.int(6);
    if (what === 0) change.heads = { [r.pick(["", "w1", "w2"])]: r.next() < 0.15 ? null : { seq: r.int(5), hash: r.pick(["a", "b"]), genesis: "g" } };
    else if (what === 1) change.forces = { [r.pick(["", "w1", "w2"])]: r.pick(["f0", "f1", ""]) };
    else if (what === 2) change.memberships = r.pick([first.memberships, [...first.memberships, { workspace: "w2", home: false }], [{ workspace: "w2", home: false }]]);
    else if (what === 3) change.chains = { [r.pick(["p1", "p2"])]: r.pick([null, [], [{ ws: "person:ada" }, {}], [{ ws: "person:" }], [{ ws: "workspace:x" }], [{ ws: 3 }, {}, {}]]) };
    await set(change);
    await ask("tells", "set", change);
    if (r.next() < 0.6) {
      cloudListener();
      await ask("tells", "cloud");
    }
    if (r.next() < 0.4) {
      const genesis = r.pick(["p1", "p2", "p3"]);
      chainListener(genesis);
      await ask("tells", "chain", { genesis });
    }
  }
  assert.deepEqual(await ask("tells", "told"), asJson(told));
  stop();
  await ask("tells", "stop");
  cloudListener();
  await ask("tells", "cloud");
  assert.deepEqual(await ask("tells", "told"), asJson(told), "nothing told once stopped");
  for (const chain of [[], [{ ws: "person:x" }], [{ ws: "person:" }], [{}], [null], [{ ws: "Person:x" }]]) await same("subOf", { chain }, () => subOf(chain));
});

// ── a reply's ways ────────────────────────────────────────────────────────────────────────────────────────────────

test("a connection's ways and a reply that went slowly, as reply-watch.ts says them", { skip }, async () => {
  const way = (o: Json) => ({ selected: false, txPackets: 0, lostPackets: 0, ...o });
  const sets: Json[][] = [
    [],
    [way({ selected: true, relay: "https://r1/", rttMs: 12.5, txPackets: 100, lostPackets: 2, cwnd: 12000, congestionEvents: 3 })],
    [way({ ip: "1.2.3.4:5", rttMs: 0.4, txPackets: 3 }), way({ relay: "https://r1/", txPackets: 7 }), way({ relay: "https://r1/", selected: true, txPackets: 9, rttMs: 70.5 }), way({ txPackets: 1 })],
    [way({ ip: "1.2.3.4:5", txPackets: 30, lostPackets: 1, rttMs: 2.49 }), way({ relay: "https://r1/", txPackets: 17 }), way({ relay: "https://r1/", txPackets: 20, cwnd: 0 }), way({ txPackets: 4 })],
  ];
  for (const paths of sets) {
    await same("pathsOf", { paths }, () => pathsOf({ paths: () => paths } as never));
    await same("sentOn", { paths }, () => sentOn({ paths: () => paths } as never));
  }
  let WALL = 0;
  const now = mock.method(wall, "now", () => WALL);
  try {
    for (const [before, paths] of [[sets[2]!, sets[3]!], [sets[1]!, sets[1]!], [[], sets[3]!], [sets[3]!, []]]) {
      for (const code of [null, 0, 7]) {
        for (const ms of [0, 4_999, 5_000, 61_234]) {
          logged.length = 0;
          WALL = 1_000_000;
          let stopped: (c: number | null) => void = () => {};
          let current = before;
          const conn = { paths: () => current, remoteId: () => "device-1" };
          slowly({ stopped: () => new Promise((r) => (stopped = r)) } as never, conn as never, () => "GET /a/:id", 3_000_000, 42, WALL);
          current = paths;
          WALL += ms;
          stopped(code);
          for (let i = 0; i < 3; i++) await new Promise<void>((r) => setImmediate(r));
          const theirs = said("mesh");
          const ours = await call("slowLine", { before, paths, ...(code !== null ? { code } : {}), ms, route: "GET /a/:id", bytes: 3_000_000, made: 42, device: "device-1" });
          assert.deepEqual(ours === null ? [] : [{ level: "info", words: "a reply went slowly", with: ours }], theirs, `slowly ${ms} ${code}`);
        }
      }
    }
  } finally {
    now.mock.restore();
  }
});

// ── the device tools ──────────────────────────────────────────────────────────────────────────────────────────────

test("the device tools' admission and answers, over the mesh and the presence socket, as tools.ts has them", { skip }, async () => {
  const states: Json[] = [
    { enabled: false, workspace: "w", gateways: ["g"] }, { enabled: true, gateways: ["g"] }, { enabled: true, workspace: "w", removed: true, gateways: ["g"] },
    { enabled: true, workspace: "w", gateways: ["h"] }, { enabled: true, workspace: "w", gateways: ["g", "h"] },
  ];
  const heads: Json[] = [
    null, 3, [], {}, { op: 5 }, { op: "fs.read" }, { op: "fs.read", context: { workspace: "w" }, args: { path: "/a" }, id: "r1" },
    { op: "fs.read", context: { workspace: "other" } }, { op: "x", context: { workspace: "w", agent: "a1" }, args: [1], id: 5 }, { op: "x", context: [], args: null },
    { op: "x", context: { workspace: "w" }, args: "s" },
  ];
  const results: Json[] = [{ value: { ok: 1 } }, { code: "not_found", message: "no such file" }, { throw: "it broke" }];
  const tsDeps = (s: Json, result: Json, ran: Json[]) => ({
    cloud: { state: s.workspace === undefined ? null : { workspace: s.workspace, gateway_keys: s.gateways }, removed: () => s.removed === true },
    tools: {
      run: (op: string, args: Json, context: Json) => {
        ran.push({ op, args, context });
        if (result.throw !== undefined) return Effect.die(new Error(result.throw));
        if (result.code !== undefined) return Effect.fail(new ToolError({ code: result.code, message: result.message }));
        return Effect.succeed(result.value);
      },
    },
    access: () => ({}),
    enabled: () => s.enabled === true,
  });
  for (const s of states) {
    for (const head of heads) {
      for (const result of results) {
        for (const over of ["mesh", "presence"]) {
          const ran: Json[] = [];
          const d = tsDeps(s, result, ran) as never;
          logged.length = 0;
          let reply: Json;
          if (over === "presence") reply = await presenceTools(d)(head);
          else {
            // over the mesh: one stream of that head line, served as a gateway's connection
            const r = await serve(d, "g", [Buffer.from(`${JSON.stringify(head)}\n`)]);
            reply = r.closed === null ? JSON.parse(r.written) : { ok: false, error: { code: "forbidden", message: r.error } };
          }
          const theirs = { reply, said: said("tools"), ran: asJson(ran), refusal: refusal(d, "g") };
          const args = { ...s, head, result, peer: "g", over };
          const ours = await call("tools", args);
          if (over === "mesh" && theirs.refusal !== null) {
            // (a connection that is no gateway's is closed before any of its streams is read)
            const served = await call("serveTools", { ...args, chunks: [hex(Buffer.from(`${JSON.stringify(head)}\n`))] });
            const r = await serve(tsDeps(s, result, []) as never, "g", [Buffer.from(`${JSON.stringify(head)}\n`)]);
            assert.deepEqual(asJson({ closed: served.closed, error: served.error, written: served.written }), asJson({ closed: r.closed, error: r.error, written: r.written }));
            continue;
          }
          assert.deepEqual(ours, asJson(theirs), `tools ${JSON.stringify(args)}`);
        }
      }
    }
  }
  // the mesh's framing: a line in pieces, one that never ends, one too long, none at all
  const d = { ...states[4], result: results[0] };
  for (const chunks of [
    [Buffer.from('{"op":"a","context":{"workspace":"w"}}\n')], [Buffer.from('{"op":"a",'), Buffer.from('"context":{"workspace":"w"}}\nrest')], [Buffer.from('{"op":"a"')], [],
  ]) {
    const ran: Json[] = [];
    logged.length = 0;
    const theirs = await serve(tsDeps(states[4], results[0], ran) as never, "g", chunks);
    const ours = await call("serveTools", { ...d, peer: "g", chunks: chunks.map(hex) });
    assert.deepEqual(asJson({ ...ours, said: ours.said, ran: ours.ran }), asJson({ ...theirs, said: said("tools"), ran }), `served ${chunks.map(String).join("|")}`);
  }
});

/// A gateway's connection of one stream of `chunks`, served by serveTools: what it wrote, whether it finished, how the
/// connection was closed and what serving it threw.
async function serve(d: never, peer: string, chunks: Buffer[]) {
  let at = 0;
  let given = false;
  const written: Buffer[] = [];
  let finished = false;
  let closed: Json = null;
  const stream = {
    read: async () => (at < chunks.length ? chunks[at++]! : null),
    write: async (b: Buffer) => void written.push(Buffer.from(b)),
    finish: async () => void (finished = true),
    stopped: async () => null,
    reset: async () => {},
  };
  const conn = { remoteId: () => peer, close: (code: number, reason: string) => void (closed = [code, reason]), acceptBi: async () => (given ? null : ((given = true), stream)) };
  let error: string | null = null;
  try {
    await serveTools(d, conn as never);
  } catch (e) {
    error = (e as Error).message;
  }
  for (let i = 0; i < 5; i++) await new Promise<void>((r) => setImmediate(r));
  return { written: Buffer.concat(written).toString("utf8"), finished, closed, error };
}

test("the chats the device tools start and drive, and where one is, as adminSessions has them", { skip }, async () => {
  const answer = (status: number, value: unknown) => ({ status, text: typeof value === "string" ? value : JSON.stringify(value) });
  const flows: Json[] = [
    { prompt: "hi", title: "T", runtime: "claude", requester: "a@x", answers: [answer(200, { key: "s1", thread: { id: 42 } }), answer(200, {})] },
    { prompt: "hi", title: null, requester: "a@x", runtimes: ["codex", "claude"], answers: [answer(200, { key: 7, thread: { thread: "t9" } }), answer(200, {})] },
    { prompt: "hi", requester: "a@x", runtimes: [], answers: [answer(200, { key: "s1", thread: {} })] },
    { prompt: "hi", requester: "a@x", runtimes: ["nope"], answers: [answer(404, { error: "no such runtime" })] },
    { prompt: "hi", requester: "a@x", answers: [answer(403, "not json")] },
    { prompt: "hi", requester: "a@x", answers: [answer(500, { error: 5 })] },
    { prompt: "hi", requester: "a@x", answers: [answer(200, { key: "s", thread: { id: "x" } }), answer(409, { error: "busy" })] },
    { prompt: "hi", requester: "a@x", answers: [answer(200, "")] },
    { say: "a/b c?é", text: "more", requester: "b@x", answers: [answer(200, {})] },
    { say: "12", text: "more", requester: "b@x", answers: [answer(404, {})] },
  ];
  for (const flow of flows) {
    const asked: Json[] = [];
    let next = 0;
    const admin = {
      handle: async (r: Json) => {
        asked.push({ as: r.viewer.email, method: r.method, path: r.path, body: JSON.parse(r.body.toString()) });
        const a = flow.answers[next++] ?? { status: 200, text: "" };
        return { status: a.status, body: Buffer.from(a.text) };
      },
    };
    const sessions = adminSessions(() => admin as never, () => null, () => flow.runtimes ?? [], () => "w", "gw");
    let result: Json;
    try {
      result = flow.say !== undefined
        ? (await sessions.say({ thread: flow.say, text: flow.text, requester: flow.requester }), null)
        : await sessions.start({ prompt: flow.prompt, title: flow.title, runtime: flow.runtime, requester: flow.requester } as never);
    } catch (e) {
      result = { error: (e as Error).message, ...((e as { code?: string }).code ? { code: (e as { code: string }).code } : {}) };
    }
    const ours = await call("toolsChat", { ...flow, kinds: RUNTIME_KINDS });
    assert.deepEqual(ours, asJson({ result, asked }), JSON.stringify(flow));
  }
  const turn = (o: Json) => ({ endedAt: 1, startedAt: 1, declared: null, ending: null, detail: null, need: null, ...o });
  const threads: Json[][] = [
    [], [null], [turn({ endedAt: null })], [turn({ declared: "all_done", detail: "did it" })], [turn({ ending: "final" })], [turn({ declared: "need_human", need: "a key" })],
    [turn({ declared: "block" }), turn({ startedAt: 5, declared: "waiting", detail: "ci" })], [turn({ startedAt: 5, declared: "waiting" }), turn({ startedAt: 5, declared: "all_done" })],
    [turn({ declared: "weird" }), null], [turn({ declared: "need_decision", detail: "" })], [turn({ declared: "need_help" }), turn({ endedAt: null })],
    [turn({ declared: "block" })], [turn({ declared: "need_help", need: "n" })], [turn({ declared: 3, ending: "final" })], [turn({ endedAt: undefined, declared: "waiting" })],
  ];
  for (const turns of threads) {
    const store = {
      getThread: () => ({}),
      threadSessions: () => turns.map((_, i) => ({ session: `s${i}` })),
      lastTurn: (k: string) => turns[Number(k.slice(1))] ?? null,
    };
    const sessions = adminSessions(() => ({}) as never, () => store as never, () => [], () => "w", "gw");
    await same("toolsStatus", { turns: turns.filter((t) => t !== null) }, () => sessions.status("1"));
  }
  // a thread as the tools name it: a whole number of the store's, else nothing
  const store = { "0": [turn({ declared: "all_done" })], "42": [null, turn({ endedAt: null })], "7": [] } as Record<string, Json[]>;
  for (const thread of ["42", " 42 ", "", "0", "abc", "1.5", "7", "9", "4.2e1", "0x2a", "-0", "Infinity"]) {
    for (const threads of [store, undefined]) {
      const st = threads === undefined ? null : {
        getThread: (id: number) => (String(id) in threads ? {} : null),
        threadSessions: (id: number) => threads[String(id)]!.map((_, i) => ({ session: `${id}/${i}` })),
        lastTurn: (k: string) => threads[k.split("/")[0]!]![Number(k.split("/")[1])] ?? null,
      };
      const sessions = adminSessions(() => ({}) as never, () => st as never, () => [], () => "w", "gw");
      await same("toolsThreadStatus", { thread, ...(threads ? { threads } : {}) }, () => sessions.status(thread));
    }
  }
  for (const s of ["a b", "é/😀?&=#", "-_.!~*'()", "\u0000"]) await same("encodeURIComponent", { s }, () => encodeURIComponent(s));
});

// ── files over the transport ──────────────────────────────────────────────────────────────────────────────────────

test("a file's bytes as they are sent, and bytes taken in, as files.ts reads and writes them", { skip }, async () => {
  const dir = fresh("mesh-runtime-files-");
  const r = rng(5);
  const content = Buffer.alloc(2_500_000 + 17);
  for (let i = 0; i < content.length; i += 997) content[i] = r.int(256);
  const path = join(dir, "f");
  writeFileSync(path, content);
  const MiB = 1024 * 1024;
  for (const [offset, end, take] of [[0, 0, undefined], [5, 3, undefined], [0, content.length, undefined], [17, 2 * MiB + 3, undefined], [100, content.length + 10, undefined], [0, content.length, 1], [0, content.length, 0]] as const) {
    await same("fileBytes", { content: hex(content), offset, end, ...(take !== undefined ? { take } : {}) }, async () => {
      const out: number[] = [];
      let error: string | null = null;
      const pieces = fileBytes(path, offset, end);
      const it = pieces[Symbol.asyncIterator]();
      try {
        for (let n = 0; take === undefined || n < take; n++) {
          const next = await it.next();
          if (next.done) break;
          out.push(next.value.length);
        }
      } catch (e) {
        error = (e as Error).message;
      }
      if (take !== undefined) await it.return?.();
      return { pieces: out, error };
    });
  }
  for (const [chunks, limit] of [[[], 0], [["0102", "03"], 3], [["0102", "03"], 2], [["", "ff"], 1]] as const) {
    await same("readBytes", { chunks, limit }, async () => {
      async function* gen() {
        for (const c of chunks) yield bytesOf(c);
      }
      try {
        return { bytes: hex(await readBytes(gen(), limit)) };
      } catch (e) {
        return { error: (e as Error).message };
      }
    });
  }
  for (const [chunks, offset, limit] of [[["0102", "0304"], 10, 100], [["0102", "0304"], 10, 13], [[], 0, 0], [["aa"], 0, 1]] as const) {
    await same("writeBytes", { chunks, offset, limit }, async () => {
      const writes: Json[] = [];
      const file = { write: async (b: Buffer, off: number, len: number, pos: number) => (writes.push([pos, hex(b.subarray(off, off + len))]), { bytesWritten: len }) };
      async function* gen() {
        for (const c of chunks) yield bytesOf(c);
      }
      try {
        return { n: await writeBytes(file as never, gen(), offset, limit), writes };
      } catch (e) {
        return { error: (e as Error).message, writes };
      }
    });
  }
  for (const bytes of ["", "00ff"]) {
    await same("oneBytes", { bytes }, async () => {
      const out: string[] = [];
      for await (const p of oneBytes(bytesOf(bytes))) out.push(hex(p));
      return out;
    });
  }
  // (stopping bytes never read reads none)
  await stopBytes(oneBytes(Buffer.alloc(1)));
});

// ── the served programs ───────────────────────────────────────────────────────────────────────────────────────────

/// A served program as the test plays it.
class Served1 extends EventEmitter implements ServingProcess {
  told: any[] = [];
  readonly path: string;
  constructor(path: string) {
    super();
    this.path = path;
  }
  postMessage(m: unknown) { this.told.push(m); }
  async terminate() { this.emit("exit", 0); return 0; }
  say(m: unknown) { this.emit("message", m); }
}

test("what the served programs are told of each connection's member, when one is started again, and the pieces they relay", { skip }, async () => {
  assert.deepEqual(await call("servedRoutes"), SERVED_ROUTES);
  const programs: Served1[] = [];
  let now = 1_000_000;
  const due: { at: number; f: () => void }[] = [];
  const relays = new Map<number, { send: (text: string) => void; ended: () => void }>();
  const answered: Json[] = [];
  const s = new Served("stillfail-reader", fresh("mesh-runtime-served-"), async (viewer) => (answered.push(viewer), { status: 200, headers: {}, body: Buffer.alloc(0) }), () => {}, async (_viewer, head) => {
    const body = { relay: (send: (t: string) => void, ended: () => void) => void relays.set(head.n, { send, ended }), [Symbol.asyncIterator]: () => ({ next: async () => ({ done: true, value: undefined }) }) };
    return { status: 200, headers: {}, body: body as never };
  }, {
    spawn: (_b, args) => {
      const p = new Served1(args[args.indexOf("--serve") + 1]!);
      programs.push(p);
      return p;
    },
    now: () => now,
    after: (ms, f) => (due.push({ at: now + ms, f }), () => {}),
  });
  const started = s.start();
  for (const p of programs) p.say({ listening: p.path });
  await started;
  const turns = async () => {
    for (let i = 0; i < 5; i++) await new Promise<void>((r) => setImmediate(r));
  };
  const plain = (ms: any[]) => ms.map(({ wall: _w, ...m }) => m);
  await make("ServedTold", "told");
  const r = rng(9);
  const viewers: Json[] = [null, { email: "a@x", name: "Ada" }, { email: "a@x", name: "Ada L" }, { email: "b@x" }, { email: "b@x", name: "" }, { email: "c@x", name: "Cy", role: "member" }];
  for (let step = 0; step < 120; step++) {
    const conn = r.int(4);
    const viewer = r.pick(viewers);
    const moved = r.next() < 0.3;
    const floor = r.pick([null, null, 9144, 9200.5]);
    for (const p of programs) p.told.length = 0;
    s.viewer(conn, viewer, moved, floor);
    const ours = await ask("told", "viewer", { conn, ...(viewer !== null ? { viewer } : {}), moved, ...(floor !== null ? { floor } : {}) });
    assert.deepEqual(ours, plain(programs[0]!.told), `step ${step} told`);
    // who the member is, as the program's fallback is answered for
    const asking = r.int(4);
    answered.length = 0;
    programs[0]!.say({ fallback: step, conn: asking, head: {} });
    await turns();
    assert.deepEqual(await ask("told", "viewerOf", { conn: asking }), asJson(answered[0] ?? null), `step ${step} viewer of ${asking}`);
  }
  // one that ends is started again (at once, having run long; a second later, having not), and told all again
  for (const ran of [SERVED_STEADY_MS + 1, SERVED_STEADY_MS, SERVED_STEADY_MS - 1, 0]) {
    const before = programs.length;
    const p = programs.at(-1)!;
    now += ran;
    p.emit("exit", 1);
    let again = 0;
    if (programs.length === before) {
      now += 1_000;
      for (const d of due.splice(0)) if (d.at <= now) d.f();
      again = 1_000;
    }
    assert.equal(programs.length, before + 1);
    assert.equal(await call("servedAgainAfter", { ran }), again, `again after ${ran}`);
    const next = programs.at(-1)!;
    next.say({ listening: next.path });
    assert.deepEqual(await ask("told", "again"), next.told.filter((m) => m.set === undefined).map((m) => asJson(m)), "what one listening again is told");
  }
  // the pieces of the streams a program relays, given once where several of its streams are told one together
  const p = programs.at(-1)!;
  s.viewer(1, { email: "a@x" });
  for (let n = 100; n < 106; n++) p.say({ fallback: n, stream: true, conn: 1, head: { n } });
  await turns();
  await make("PieceQueue", "q");
  for (let round = 0; round < 25; round++) {
    p.told.length = 0;
    // (told in one turn of the loop, as a stream's pieces are: what is told across turns is given apart)
    const steps = Array.from({ length: r.int(8) }, () => ({ k: r.int(6), text: r.next() < 0.15 ? null : r.pick(["a", "b", "{\"x\":1}\n"]) }));
    for (const { k, text } of steps) {
      if (text === null) relays.get(100 + k)!.ended();
      else relays.get(100 + k)!.send(text);
    }
    for (const { k, text } of steps) await ask("q", "piece", { n: 100 + k, ...(text !== null ? { text } : {}) });
    await turns();
    assert.deepEqual(await ask("q", "drain"), p.told.filter((m) => m.chunk !== undefined || m.pieces !== undefined || m.done !== undefined), `round ${round}`);
  }
  await s.close();
});

// ── a screen's view, end to end ───────────────────────────────────────────────────────────────────────────────────

/// A hub, a source and its view of the test's, each doing only what the test says (as the harness's world does,
/// mesh_runtime/harness_screens.mbt), on a clock of the view's own: every call answerScreen makes of them, every byte it
/// writes and every line it says, kept.
class ScreenWorld {
  calls: Json[] = [];
  writes: string[] = [];
  finished = false;
  done = false;
  error: string | null = null;
  writeFails = false;
  frames: Json[] = [];
  nextWaiting: ((e: Json) => void) | null = null;
  audio: Json[] = [];
  audioWaiting: ((e: Json) => void) | null = null;
  reads: (Buffer | null)[] = [];
  readWaiting: ((b: Buffer | null) => void) | null = null;
  stoppedNow: () => void = () => {};
  listeners = new Map<string, (v: Json) => void>();
  watchers: (() => void)[] = [];
  stoppers: (() => void)[] = [];
  joined: Json = null;
  title: string;
  site: string | undefined;
  address: string | undefined;
  gone = false;
  paths: Json[] = [];
  readonly scope = Effect.runSync(Scope.make());
  readonly clock = Effect.runSync(Scope.provide(TestClock.make(), this.scope));
  readonly conf: Json;

  constructor(conf: Json) {
    this.conf = conf;
    this.title = conf.source?.title ?? "";
    this.site = conf.source?.site ?? undefined;
    this.address = conf.source?.address ?? undefined;
    const source = this.#source();
    const hub = this.#hub(source);
    const stopped = new Promise<null>((r) => (this.stoppedNow = () => r(null)));
    const stream = {
      read: async () => (this.reads.length > 0 ? this.reads.shift()! : new Promise<Buffer | null>((r) => (this.readWaiting = r))),
      write: async (b: Buffer) => {
        if (this.writeFails) throw new Error("the stream is gone");
        this.writes.push(hex(b));
      },
      finish: async () => void (this.finished = true),
      stopped: () => stopped,
      reset: async () => {},
      // (`mediaDatagrams` in the world: what the stream's addon or front answers; none, one from before)
      ...(typeof conf.mediaDatagrams === "boolean" ? { mediaDatagrams: async (token: number) => (this.calls.push(["mediaDatagrams", token]), conf.mediaDatagrams) } : {}),
    };
    this.paths = Array.isArray(conf.paths) ? conf.paths : [];
    const conn = Array.isArray(conf.paths) ? { paths: () => (this.calls.push(["paths"]), this.paths) } : undefined;
    answerScreen(hub as never, stream as never, bytesOf(conf.carry ?? ""), conf.head ?? null, conf.viewer ?? null, () => conf.up !== false, this.clock, conn as never).then(
      () => void (this.done = true),
      (e) => ((this.error = (e as Error).message), (this.done = true)),
    );
  }

  #source() {
    const s = this.conf.source ?? {};
    const v = this.conf.view ?? {};
    const w = this;
    const watch = (name: string) => (v[name] ? { [name]: (f: (x: Json) => void) => (w.listeners.set(name, f), () => (w.calls.push([`un:${name}`]), w.listeners.delete(name))) } : {});
    const view = {
      next: async () => {
        w.calls.push(["next"]);
        const e: Json = w.frames.length > 0 ? w.frames.shift() : await new Promise((r) => (w.nextWaiting = r));
        if (e?.frame) {
          const f = e.frame;
          const c = f.config;
          return {
            ...(c ? { config: { codec: c.codec, width: c.width, height: c.height, ...(typeof c.description === "string" ? { description: new Uint8Array(bytesOf(c.description)) } : {}), ...(c.region ? { region: c.region } : {}) } } : {}),
            key: f.key === true, ts: f.ts, data: new Uint8Array(bytesOf(f.data ?? "")),
          };
        }
        if (e?.refused) throw new ScreenRefused(e.refused.status, e.refused.key, e.refused.args ?? {}, e.refused.access ?? undefined);
        if (e?.error !== undefined) throw new Error(e.error);
        return null;
      },
      ...(v.audio ? { nextAudio: async () => {
        const e: Json = w.audio.length > 0 ? w.audio.shift() : await new Promise((r) => (w.audioWaiting = r));
        if (e?.audio) return { ts: e.audio.ts, data: new Uint8Array(bytesOf(e.audio.data)), codec: e.audio.codec };
        if (e?.error !== undefined) throw new Error(e.error);
        return null;
      } } : {}),
      keyframe: () => void w.calls.push(["keyframe"]),
      input: async (e: Json) => {
        w.calls.push(["input", e]);
        if (v.inputFails) throw new Error("input refused");
      },
      ...(v.rate ? { rate: (r: number) => void w.calls.push(["rate", r]) } : {}),
      ...(v.bounds ? { bounds: (...a: Json[]) => void w.calls.push(a.length > 2 ? ["bounds", a[0], a[1], a[2]] : ["bounds", a[0], a[1]]) } : {}),
      ...(v.regionsSaid ? { regions: () => v.regions === true } : {}),
      ...(v.video !== undefined ? { video: () => v.video } : {}),
      ...(v.whySaid ? { why: () => v.why ?? undefined } : {}),
      close: () => {
        w.calls.push(["close"]);
        const n = w.nextWaiting, a = w.audioWaiting;
        w.nextWaiting = null;
        w.audioWaiting = null;
        n?.(null);
        a?.(null);
      },
      ...(v.setClipboard ? { setClipboard: async (clip: Json, paste: boolean) => void w.calls.push(["setClipboard", clip.type === "text" ? clip : { type: "png", data: hex(clip.data) }, paste]) } : {}),
      ...(v.watchClipboard ? { watchClipboard: (f: (c: Json) => void) => (w.listeners.set("clip", (c) => f(c.type === "png" ? { type: "png", data: new Uint8Array(bytesOf(c.data)) } : c)), () => (w.calls.push(["un:watchClipboard"]), w.listeners.delete("clip"))) } : {}),
      ...watch("watchCursor"), ...watch("watchTurn"), ...watch("watchWindows"), ...watch("watchLogin"), ...watch("watchPasskey"),
      ...(v.window ? { window: (id: number | null) => void w.calls.push(["window", id]) } : {}),
      ...(v.reveal ? { reveal: async (p: string) => void w.calls.push(["reveal", p]) } : {}),
      ...(v.fill ? { fill: async (f: Json) => void w.calls.push(["fill", f]) } : {}),
      ...(v.passkey ? { passkey: async (a: Json) => void w.calls.push(["passkey", a]) } : {}),
      ...(v.watchChild ? { watchChild: (f: (s: string) => void) => (w.listeners.set("watchChild", (s) => f(s)), () => (w.calls.push(["un:watchChild"]), w.listeners.delete("watchChild"))) } : {}),
    };
    return {
      id: s.id, kind: s.kind ?? "browser",
      title: () => w.title,
      open: async (options: Json) => {
        w.calls.push(["open", asJson(options)]);
        if (v.refuse) throw new ScreenRefused(v.refuse.status, v.refuse.key, v.refuse.args ?? {}, v.refuse.access ?? undefined);
        if (typeof v.fail === "string") throw new Error(v.fail);
        if (s.goneWhileOpening) w.gone = true;
        return view;
      },
      ...(s.access !== undefined ? { access: () => s.access } : {}),
      ...(Array.isArray(s.clipboard) ? { clipboard: () => s.clipboard } : {}),
      ...(s.reveal ? { reveal: true } : {}),
      ...(s.peek ? { peek: true } : {}),
      ...(s.openUrl ? { openUrl: async () => {} } : {}),
      ...(s.userTab ? { userTab: true } : {}),
      ...(s.sleeping !== undefined ? { sleeping: () => s.sleeping === true } : {}),
      ...(s.hasSite ? { site: () => w.site } : {}),
      ...(s.hasAddress ? { address: () => w.address } : {}),
      ...(s.scale !== undefined ? { scale: async () => s.scale } : {}),
      ...(s.setScale ? { setScale: async (p: number) => {
        w.calls.push(["setScale", p]);
        if (s.setFails) throw new Error("not that one");
        return { percent: p };
      } } : {}),
      ...(s.resolution !== undefined ? { resolution: async () => s.resolution } : {}),
      ...(s.setResolution ? { setResolution: async (width: number, height: number) => {
        w.calls.push(["setResolution", width, height]);
        if (s.setFails) throw new Error("not that one");
        return { width, height };
      } } : {}),
    };
  }

  #hub(source: unknown) {
    const w = this;
    return {
      get: (id: string) => (id === w.conf.source?.id && !w.gone ? source : undefined),
      drive: (id: string, device: string, taken: boolean, by: string) => {
        w.calls.push(["drive", id, device, taken, by]);
        return { control: w.conf.drive?.control === true, took: w.conf.drive?.took ?? [] };
      },
      join: (id: string, watcher: Json) => {
        w.calls.push(["join", id, { name: watcher.name, device: watcher.device, self: watcher.self ?? null, client: watcher.client ?? null, app: watcher.app ?? null, control: watcher.control }]);
        w.joined = watcher;
        return () => void w.calls.push(["leave"]);
      },
      watch: (f: () => void) => (w.watchers.push(f), () => (w.calls.push(["unwatch"]), (w.watchers = []))),
      whenStopping: (f: () => void) => (w.stoppers.push(f), () => (w.calls.push(["unstop"]), (w.stoppers = []))),
    };
  }

  #give(queue: Json[], waiting: "nextWaiting" | "audioWaiting", e: Json) {
    const d = this[waiting];
    if (d !== null) {
      this[waiting] = null;
      d(e);
    } else queue.push(e);
  }

  async step(a: Json) {
    switch (a.op) {
      case "client":
      case "clientEnd": {
        const b = a.op === "client" ? bytesOf(a.bytes) : null;
        const d = this.readWaiting;
        if (d !== null) {
          this.readWaiting = null;
          d(b);
        } else this.reads.push(b);
        break;
      }
      case "frame": this.#give(this.frames, "nextWaiting", { frame: a.frame }); break;
      case "frameNull": this.#give(this.frames, "nextWaiting", null); break;
      case "frameRefused": this.#give(this.frames, "nextWaiting", { refused: a.refused }); break;
      case "frameError": this.#give(this.frames, "nextWaiting", { error: a.error }); break;
      case "audio": this.#give(this.audio, "audioWaiting", { audio: a.audio }); break;
      case "audioNull": this.#give(this.audio, "audioWaiting", null); break;
      case "clip": this.listeners.get("clip")?.(a.clip); break;
      case "listener": this.listeners.get(a.name)?.(a.value); break;
      case "change":
        if (typeof a.title === "string") this.title = a.title;
        if (a.site !== undefined) this.site = a.site ?? undefined;
        if (a.address !== undefined) this.address = a.address ?? undefined;
        if (a.gone === true) this.gone = true;
        for (const f of [...this.watchers]) f();
        break;
      case "stopping": for (const f of [...this.stoppers]) f(); break;
      case "watchOnly": this.joined?.watchOnly(a.by ?? undefined); break;
      case "end": this.joined?.end(a.by ?? ""); break;
      case "tell": this.joined?.tell(a.people); break;
      case "stopped": this.stoppedNow(); break;
      case "writeFails": this.writeFails = true; break;
      case "paths": this.paths = a.paths; break;
      case "advance": await Effect.runPromise(this.clock.adjust(a.ms)); break;
    }
    await settled();
  }

  told() {
    const out = { calls: asJson(this.calls), writes: this.writes, logs: said("screens").map((l) => ({ ...l, at: "screens" })), finished: this.finished, done: this.done, error: this.error };
    this.calls = [];
    this.writes = [];
    return out;
  }
}

/// Turns of the loop for what was set going to come back (no timer: the view's clock moves only as the test says).
const settled = async () => {
  for (let i = 0; i < 12; i++) await new Promise<void>((r) => setImmediate(r));
};

/// The words the view says, as the TypeScript has them: each template of the station's screens, given the program.
let wordsGiven = false;
async function giveWords() {
  if (wordsGiven) return;
  const keys = Object.keys(JSON.parse(readFileSync(join(import.meta.dirname, "../../client/i18n/catalog/en/station.json"), "utf8"))).filter((k) => k.startsWith("station.screen."));
  const words: Record<string, string> = {};
  for (const lang of ["zh", "en"] as const) for (const key of keys) words[`${lang}\u0000${key}`] = tr(lang, key);
  await call("words", { words });
  wordsGiven = true;
}

let worlds = 0;
/// One world on both: opened, then each step said to both and what each came to compared.
async function bothScreens(conf: Json, steps: Json[], what: string) {
  await giveWords();
  const name = `screen-${++worlds}`;
  logged.length = 0;
  const ts = new ScreenWorld(conf);
  // (a frame's capture time is on the host's clock, screen-pace.ts hostNow: the world's here, as the program's)
  const host = mock.method(process.hrtime, "bigint", () => ts.clock.monotonicTimeNanosUnsafe());
  try {
    await settled();
    const opened = await answered(await mb().ask("new", { kind: "Screen", as: name, args: conf }));
    assert.equal(opened, null);
    assert.deepEqual(await ask(name, "told"), ts.told(), `${what}: opened`);
    for (const [i, step] of steps.entries()) {
      await ts.step(step);
      const ours = await ask(name, "step", step);
      assert.deepEqual(ours, ts.told(), `${what}: step ${i} ${JSON.stringify(step).slice(0, 200)}`);
    }
  } finally {
    host.mock.restore();
  }
  await Effect.runPromise(Scope.close(ts.scope, Exit.void));
}

const viewHead = (o: Json = {}) => ({ method: "POST", path: "/admin/api/screens/browser%3At1/view", headers: { "stillfail-lang": "en" }, screen: { codecs: ["h264", "jpeg"], control: true }, ...o });
const member = { name: "Ada", email: "ada@x", role: "member", device: "dev-1" };
const browserSource = (o: Json = {}) => ({ id: "browser:t1", kind: "browser", title: "A page", hasSite: true, site: "a.com", hasAddress: true, address: "https://a.com/x", openUrl: true, clipboard: ["text", "png"], reveal: true, ...o });
const fullView = (o: Json = {}) => ({
  rate: true, bounds: true, regionsSaid: true, regions: true, video: { capture: "cdp" }, audio: true, setClipboard: true, watchClipboard: true, watchCursor: true, watchTurn: true,
  watchWindows: true, window: true, reveal: true, watchLogin: true, fill: true, watchPasskey: true, passkey: true, watchChild: true, ...o,
});
const vframe = (ts: number, o: Json = {}) => ({ op: "frame", frame: { key: false, ts, data: "00010203", ...o } });
const clientFrame = (kind: number, payload: Buffer) => ({ op: "client", bytes: hex(frame(kind, payload)) });
const ackOf = (ts: number) => {
  const b = Buffer.alloc(8);
  b.writeBigUInt64BE(BigInt(ts));
  return clientFrame(17, b);
};
const inputOf = (v: Json) => clientFrame(16, Buffer.from(JSON.stringify(v)));

test("a screen's view refused, as answerScreen refuses it", { skip }, async () => {
  const ok = { head: viewHead(), viewer: member, source: browserSource(), view: fullView(), drive: { control: true } };
  const cases: [string, Json][] = [
    ["a GET", { ...ok, head: viewHead({ method: "get" }) }],
    ["a path of another", { ...ok, head: viewHead({ path: "/admin/api/screens/a/b/view" }) }],
    ["a path with a query", { ...ok, head: viewHead({ path: "/admin/api/screens/a?x/view" }) }],
    ["no path", { ...ok, head: viewHead({ path: 3 }) }],
    ["the long s", { ...ok, head: viewHead({ method: "poſt" }) }],
    ["not started", { ...ok, up: false }],
    ["an id that is no UTF-8", { ...ok, head: viewHead({ path: "/admin/api/screens/%E0%A4/view" }) }],
    ["an id that is a lone %", { ...ok, head: viewHead({ path: "/admin/api/screens/a%2/view" }) }],
    ["no such screen", { ...ok, head: viewHead({ path: "/admin/api/screens/desktop/view" }) }],
    ["no codec of ours", { ...ok, head: viewHead({ screen: { codecs: ["vp9"] } }) }],
    ["a preview of what is not previewed", { ...ok, head: viewHead({ screen: { codecs: ["jpeg"], peek: true } }) }],
    ["a viewer of a sleeping tab", { ...ok, viewer: { ...member, role: "viewer" }, source: browserSource({ sleeping: true }) }],
    ["a refusal with what is missing", { ...ok, head: viewHead({ headers: { "StillFail-Lang": "zh-CN" } }), view: { refuse: { status: 403, key: "station.screen.notFound", access: { capture: false, control: false, app: "Helper X", asking: true, path: "/Apps" } } } }],
    ["a refusal for Linux", { ...ok, view: { refuse: { status: 409, key: "x", access: { capture: true, control: true, reason: "linuxTools" } } } }],
    ["a refusal of an unsupported platform", { ...ok, view: { refuse: { status: 409, key: "x", access: { capture: true, control: false, unsupported: "platform" } } } }],
    ["a refusal with all there", { ...ok, view: { refuse: { status: 409, key: "station.screen.failed", args: { said: "busy" }, access: { capture: true, control: true } } } }],
    ["a failure", { ...ok, view: { fail: "no display" } }],
    ["gone as it opened", { ...ok, source: browserSource({ goneWhileOpening: true }) }],
  ];
  for (const [what, conf] of cases) await bothScreens(conf, [], what);
  await bothScreens(ok, [], "opened");
});

test("a screen's view driven step by step: frames paced by acknowledgements, its sound, its state and its input", { skip }, async () => {
  const conf = {
    head: viewHead({ screen: { codecs: ["h264"], control: true, audio: "pcm_s16le", opus: true, quality: "hd", fps: 60, client: "Phone", app: "ios", self: "me", taken: true, maxWidth: 1920, maxHeight: 1080 } }),
    viewer: member, source: browserSource({ scale: { percent: 150 }, setScale: true, resolution: null, setResolution: true }), view: fullView(), drive: { control: true, took: ["Bob"] },
  };
  const silence = "00".repeat(64);
  const steps: Json[] = [
    vframe(1_000, { key: true, config: { codec: "h264", width: 1920, height: 1080, description: "0142", region: { x: 0, y: 0, w: 0.5, h: 0.5 } } }),
    vframe(2_000), vframe(3_000),
    { op: "audio", audio: { ts: 10, data: "0102", codec: "pcm_s16le" } },
    { op: "advance", ms: 20 }, ackOf(1_000), ackOf(2_000), { op: "advance", ms: 5 }, vframe(4_000), { op: "advance", ms: 17 }, vframe(5_000),
    { op: "audio", audio: { ts: 20, data: "0304", codec: "pcm_s16le" } },
    ...Array.from({ length: 11 }, (_, i) => ({ op: "audio", audio: { ts: 30 + i, data: silence, codec: "pcm_s16le" } })),
    { op: "audio", audio: { ts: 50, data: "ff", codec: "opus" } },
    clientFrame(21, Buffer.from([0])), { op: "audio", audio: { ts: 51, data: "0506", codec: "pcm_s16le" } }, clientFrame(21, Buffer.from([1])),
    ackOf(5_000), { op: "advance", ms: 600 }, clientFrame(18, Buffer.alloc(0)),
    clientFrame(20, Buffer.from(JSON.stringify({ region: { x: 0.25, y: 0.25, w: 0.5, h: 0.5 }, maxWidth: 800, maxHeight: 600 }))),
    clientFrame(20, Buffer.from(JSON.stringify({ region: { x: 0.25, y: 0.25, w: 0.5, h: 0.5 }, maxWidth: 800, maxHeight: 600 }))),
    clientFrame(20, Buffer.from("{}")),
    inputOf({ t: "key", kind: "down", key: "a", code: "KeyA", mods: 0 }), inputOf({ t: "key", kind: "down", key: "Shift", code: "", mods: 8 }),
    inputOf({ t: "pointer", kind: "down", x: 0.5, y: 0.5, buttons: 1 }), inputOf({ t: "window", id: 7 }), inputOf({ t: "window" }), inputOf({ t: "scale", percent: 200 }),
    inputOf({ t: "resolution", width: 1280, height: 720 }), inputOf({ t: "reveal", path: "/tmp/a" }), inputOf({ t: "fill", host: "a.com", password: "p" }),
    inputOf({ t: "passkey", id: "k1", error: "NotAllowedError" }), inputOf({ t: "nope" }), { op: "client", bytes: hex(frame(16, Buffer.from("not json"))) },
    clientFrame(19, Buffer.from([1, 1, 0x68, 0x69])), { op: "clip", clip: { type: "text", text: "hi" } }, { op: "clip", clip: { type: "text", text: "yo" } }, { op: "clip", clip: { type: "text", text: "yo" } },
    { op: "clip", clip: { type: "png", data: "89" } }, { op: "listener", name: "watchLogin", value: { host: "a.com", field: "password" } },
    { op: "listener", name: "watchPasskey", value: null }, { op: "listener", name: "watchChild", value: "browser:t2" }, { op: "listener", name: "watchCursor", value: { x: 0.1, y: 0.2, shape: "text" } },
    { op: "listener", name: "watchWindows", value: { windows: [{ id: 7, app: "A", title: "t" }], window: 7, extra: 1 } }, { op: "listener", name: "watchTurn", value: 1 },
    { op: "change", title: "Another page" }, { op: "change", site: null }, { op: "change", address: "x".repeat(3000) }, { op: "change", site: "b.com", address: "https://b.com" },
    { op: "tell", people: { viewers: ["Ada", "Bob"], controlledBy: ["Ada"] } },
    clientFrame(99, Buffer.from("later")), { op: "watchOnly", by: "Bob" }, inputOf({ t: "key", kind: "up", key: "a", code: "KeyA", mods: 0 }), inputOf({ t: "window", id: 3 }),
    { op: "clip", clip: { type: "text", text: "after" } }, vframe(6_000), { op: "advance", ms: 2_000 }, { op: "clientEnd" },
  ];
  await bothScreens(conf, steps, "driven");
});

test("a screen's view ending every way it ends", { skip }, async () => {
  const base = { head: viewHead(), viewer: member, source: browserSource(), view: fullView(), drive: { control: true } };
  const desktop = { ...base, head: viewHead({ path: "/admin/api/screens/desktop/view" }), source: browserSource({ id: "desktop", kind: "desktop" }) };
  const endings: [string, Json, Json[]][] = [
    ["the client finished", base, [vframe(1), { op: "clientEnd" }]],
    ["the stream stopped", base, [{ op: "stopped" }]],
    ["the station stopping", base, [vframe(1), { op: "stopping" }]],
    ["ended by another", base, [{ op: "end", by: "Bob" }]],
    ["the source gone", base, [{ op: "change", gone: true }]],
    ["no frame more", base, [vframe(1), { op: "frameNull" }]],
    ["a desktop's capture ended", desktop, [{ op: "frameNull" }]],
    ["a desktop's capture ended, saying why", { ...desktop, view: fullView({ whySaid: true, why: "ffmpeg exited" }) }, [{ op: "frameNull" }]],
    ["a desktop gone", desktop, [{ op: "change", gone: true }, { op: "frameNull" }]],
    ["a frame refused", base, [{ op: "frameRefused", refused: { status: 403, key: "station.screen.captureEnded", args: { said: "x" } } }]],
    ["a frame refused with access", base, [{ op: "frameRefused", refused: { status: 403, key: "k", access: { capture: false, control: true } } }]],
    ["a frame that failed", base, [{ op: "frameError", error: "boom" }, vframe(2)]],
    ["a frame too large from the client", base, [{ op: "client", bytes: hex(Buffer.from([16, 0, 2, 0, 0])) }]],
    ["the stream broke as it wrote", base, [{ op: "writeFails" }, vframe(1)]],
    ["inputs that fail", { ...base, view: fullView({ inputFails: true }) }, [inputOf({ t: "text", text: "a" }), inputOf({ t: "text", text: "b" })]],
    ["a scale not set", { ...base, source: browserSource({ setScale: true, setResolution: true, setFails: true }) }, [inputOf({ t: "scale", percent: 125 }), inputOf({ t: "resolution", width: 800, height: 600 })]],
    ["a peek", { ...base, head: viewHead({ screen: { codecs: ["jpeg", "h264"], peek: true, control: true } }), source: browserSource({ peek: true }) }, [vframe(1, { config: { codec: "jpeg", width: 10, height: 10 } }), { op: "clientEnd" }]],
    ["a viewer, driving nothing", { ...base, viewer: { ...member, role: "viewer", name: "" } }, [inputOf({ t: "text", text: "a" }), inputOf({ t: "window" }), { op: "clip", clip: { type: "text", text: "c" } }, { op: "clientEnd" }]],
    ["driven elsewhere, it only looks", { ...base, drive: { control: false } }, [inputOf({ t: "text", text: "a" })]],
    ["missing control", { ...base, source: browserSource({ access: { capture: true, control: false, app: "" } }) }, [inputOf({ t: "text", text: "a" })]],
    ["muted, then the pictures", { ...base, head: viewHead({ screen: { codecs: ["h264"], control: true, audio: "pcm_s16le" } }) }, [{ op: "audio", audio: { ts: 1, data: "01", codec: "pcm_s16le" } }, { op: "audioNull" }, vframe(1)]],
  ];
  for (const [what, conf, steps] of endings) await bothScreens(conf, steps, what);
  // what of the link was lost, said each second as it changes (a preview's, never)
  const way = (tx: number, lost: number, id = "p1") => [{ id, selected: true, txPackets: tx, lostPackets: lost }];
  const lossy = { ...base, paths: way(100, 0) };
  await bothScreens(lossy, [
    { op: "advance", ms: 1000 }, { op: "paths", paths: way(200, 10) }, { op: "advance", ms: 1000 }, { op: "advance", ms: 1000 },
    { op: "paths", paths: way(205, 10) }, { op: "advance", ms: 999 }, { op: "advance", ms: 1 }, { op: "paths", paths: way(10, 1, "p2") }, { op: "advance", ms: 1000 },
    { op: "paths", paths: way(400, 90, "p2") }, { op: "advance", ms: 1000 }, { op: "paths", paths: [] }, { op: "advance", ms: 61_000 }, { op: "clientEnd" }, { op: "advance", ms: 1000 },
  ], "lost on its link");
  await bothScreens({ ...lossy, head: viewHead({ screen: { codecs: ["jpeg"], peek: true } }), source: browserSource({ peek: true }) }, [{ op: "paths", paths: way(300, 50) }, { op: "advance", ms: 2000 }], "a preview's loss");
});

test("a screen's view that reads `cursor` frames, started at the rate its link carries, its moving screen's key frames asked again", { skip }, async () => {
  const lan = [{ id: "p1", selected: true, relay: null, ip: "192.168.1.9:7000", rttMs: 3, txPackets: 0, lostPackets: 0 }];
  const cursorSteps: Json[] = [
    vframe(1_000, { key: true, config: { codec: "h264", width: 1920, height: 1080 } }),
    { op: "listener", name: "watchCursor", value: { x: 0.123456, y: 0.5, shape: "pointer" } }, { op: "listener", name: "watchCursor", value: null },
    { op: "listener", name: "watchCursor", value: { x: 2, y: -1, shape: "x".repeat(65) } }, { op: "clientEnd" },
  ];
  const binary = { head: viewHead({ screen: { codecs: ["h264"], control: true, binaryCursor: true } }), viewer: member, source: browserSource(), view: fullView(), drive: { control: true }, paths: lan };
  await bothScreens(binary, cursorSteps, "cursor frames on a LAN");
  await bothScreens({ ...binary, head: viewHead({ screen: { codecs: ["h264"], control: true } }) }, cursorSteps, "a client before cursor frames");
  await bothScreens({ ...binary, paths: [{ ...lan[0], relay: "https://r1/", ip: null, rttMs: 20 }] }, [{ op: "clientEnd" }], "a near relay");
  // frames as datagrams: the client's token, the stream asked, the reply saying so where it sends them so
  const dgram = { ...binary, head: viewHead({ screen: { codecs: ["h264"], control: true, datagrams: 3_000_000_007 } }) };
  await bothScreens({ ...dgram, mediaDatagrams: true }, [{ op: "clientEnd" }], "frames as datagrams");
  await bothScreens({ ...dgram, mediaDatagrams: false }, [{ op: "clientEnd" }], "a link with no datagrams");
  await bothScreens(dgram, [{ op: "clientEnd" }], "a stream that sends none");
  // frames at 60 a second, each acknowledged: the rate climbs, a key frame asked once it doubled the last one's
  const moving: Json[] = [vframe(1_000, { key: true, config: { codec: "h264", width: 1920, height: 1080 } })];
  for (let i = 1; i < 200; i++) moving.push({ op: "advance", ms: 17 }, ackOf(i * 1_000), vframe((i + 1) * 1_000, i % 90 === 0 ? { key: true } : {}));
  moving.push({ op: "clientEnd" });
  await bothScreens({ ...binary, paths: undefined }, moving, "a screen that keeps changing");
});

test("a screen's view on a random link: frames, acknowledgements, sound and time, step for step", { skip }, async () => {
  for (let seed = 1; seed <= 6; seed++) {
    const r = rng(100 + seed);
    const fps = r.pick([undefined, 60, 15]);
    const conf = {
      head: viewHead({ screen: { codecs: ["h264"], control: true, audio: "pcm_s16le", ...(fps ? { fps } : {}), quality: r.pick([undefined, "smooth", "original"]) } }),
      viewer: member, source: browserSource(), view: fullView({ regions: r.next() < 0.5 }), drive: { control: true },
    };
    let ts = 0;
    const given: number[] = [];
    const steps: Json[] = [];
    for (let i = 0; i < 160; i++) {
      const what = r.int(8);
      if (what <= 2) {
        ts += 1 + r.int(30_000);
        given.push(ts);
        steps.push(vframe(ts, { ...(r.next() < 0.1 ? { config: { codec: "h264", width: r.pick([1920, 1280, 3840]), height: r.pick([1080, 720, 2160]) } } : {}), data: "ab".repeat(1 + r.int(4000)) }));
      } else if (what === 3 && given.length > 0) steps.push(ackOf(r.pick(given)));
      else if (what === 4) steps.push({ op: "advance", ms: r.pick([1, 10, 16, 100, 600]) });
      else if (what === 5) steps.push({ op: "audio", audio: { ts: i, data: r.next() < 0.5 ? "0000" : "0102", codec: r.pick(["pcm_s16le", "opus"]) } });
      else if (what === 6) steps.push(clientFrame(20, Buffer.from(JSON.stringify({ region: r.next() < 0.3 ? null : { x: r.next(), y: r.next(), w: 0.4, h: 0.4 }, maxWidth: r.pick([800, 1920]), maxHeight: 600 }))));
      else steps.push(clientFrame(r.pick([18, 21]), Buffer.from([r.int(2)])));
    }
    steps.push({ op: "clientEnd" });
    await bothScreens(conf, steps, `seed ${seed}`);
  }
});

// ── the front's client ────────────────────────────────────────────────────────────────────────────────────────────

test("a connection's streams taken in the order its other end opened them, as Incoming takes them", { skip }, async () => {
  const r = rng(21);
  for (let round = 0; round < 40; round++) {
    const steps: Json[] = [];
    let index = 0;
    const pending: number[] = [];
    for (let i = 0; i < 14; i++) {
      const what = r.int(6);
      if (what <= 1) pending.push(index++);
      if (what <= 1 && r.next() < 0.5 && pending.length > 0) {
        const at = pending.splice(r.int(pending.length), 1)[0]!;
        steps.push(r.next() < 0.2 ? { skip: at } : { give: [100 + at, at] });
      } else if (what === 2) steps.push({ give: [500 + i] });
      else if (what === 3 || what === 4) steps.push({ take: true });
      else if (what === 5 && r.next() < 0.15) steps.push({ end: true });
    }
    for (const at of pending) steps.push({ give: [100 + at, at] });
    steps.push({ take: true }, { take: true });
    await same("incoming", { steps }, async () => {
      const i = new Incoming();
      const taken: Json[] = [];
      const destroyed: number[] = [];
      for (const s of steps) {
        if (s.give) i.give({ socket: { destroy: () => void destroyed.push(s.give[0]) } as never, carry: Buffer.alloc(0), id: s.give[0], ...(s.give.length > 1 ? { index: s.give[1] } : {}) });
        else if (s.skip !== undefined) i.skip(s.skip);
        else if (s.take) void i.take().then((c) => void taken.push(c === null ? null : c.id));
        else if (s.end) i.end();
        await Promise.resolve();
        await Promise.resolve();
      }
      return { taken, destroyed };
    }, `incoming round ${round}`);
  }
  for (const url of ["https://r/", "https://r", "https://r///", "", "/"]) await same("bare", { url }, () => url.replace(/\/+$/, ""));
});

/// A front of the test's on a Unix socket, as the station's would answer (mb/src/front/mesh.mbt): every ask kept, the
/// streams path normalised; what it answers and the connections and streams it gives, the test's.
class FakeFront {
  readonly path: string;
  asks: Json[] = [];
  #server: Server | null = null;
  #controls: Socket[] = [];
  #accepts: ((v: Json) => void)[] = [];
  #closedWaiters = new Map<number, (v: Json) => void>();
  #streamsPath = "";
  #nextStream = 100;
  readonly streams = new Map<number, { socket: Socket; frames: string[]; ended: boolean }>();
  refuse = new Set<string>();
  #arrived: (() => void)[] = [];
  constructor(path: string) {
    this.path = path;
  }

  async listen() {
    await rm(this.path, { force: true });
    this.#server = createServer((s) => this.#control(s));
    await new Promise<void>((resolve) => this.#server!.listen(this.path, resolve)); // a Unix socket, by its path
  }

  #control(s: Socket) {
    this.#controls.push(s);
    s.on("error", () => {});
    createInterface({ input: s }).on("line", (line) => {
      const { id, op, ...args } = JSON.parse(line);
      if (typeof args.streams === "string") {
        this.#streamsPath = args.streams;
        args.streams = "<streams>";
      }
      this.asks.push({ op, ...args });
      for (const f of this.#arrived.splice(0)) f();
      const ok = (v: Json) => s.write(`${JSON.stringify({ id, ok: v })}\n`);
      if (this.refuse.has(op)) return void s.write(`${JSON.stringify({ id, error: "no operation" })}\n`);
      switch (op) {
        case "bind": return ok({ id: "station-1", sockets: ["0.0.0.0:7777", "[::]:7777"] });
        case "relayStatus": return ok([{ url: "https://r1.example/", connected: true, access: "ok" }]);
        case "accept": return void this.#accepts.push(ok);
        case "conn.closed": return void this.#closedWaiters.set(args.conn, ok);
        case "conn.seen": return ok({ conn: args.conn, remote: "peer", alpn: "6161", via: "relay", paths: [{ selected: true, relay: "https://r1/", rttMs: 9, txPackets: 3, lostPackets: 0 }], stats: { rxBytes: 1 } });
        case "conn.answers": return ok(true);
        case "openBi":
        case "openUni": {
          const stream = this.#nextStream++;
          ok({ stream });
          return void this.#stream(args.conn, stream, 1);
        }
        case "stopped": return ok({ code: args.stream % 2 === 0 ? 7 : null });
        default: return ok(null);
      }
    });
  }

  /// Once `ready` holds, looked at again as each ask or frame comes (`what` it waits for: said where it does not).
  async until(ready: () => boolean, what = "what the front waits for") {
    await within(what, (async () => {
      while (!ready()) await new Promise<void>((r) => this.#arrived.push(r));
    })());
  }

  /// A stream's socket to the station's streams path: its head (conn, stream, kind, index), then frames as said.
  #stream(conn: number, stream: number, kind: number, index?: number) {
    const s = connect(this.#streamsPath);
    const head = Buffer.alloc(index === undefined ? 17 : 25);
    head.writeBigUInt64BE(BigInt(conn), 0);
    head.writeBigUInt64BE(BigInt(stream), 8);
    head[16] = kind;
    if (index !== undefined) head.writeBigUInt64BE(BigInt(index), 17);
    s.write(head);
    const kept = { socket: s, frames: [] as string[], ended: false };
    this.streams.set(stream, kept);
    let carry = Buffer.alloc(0);
    s.on("data", (d) => {
      carry = Buffer.concat([carry, d]);
      while (carry.length >= 4) {
        const n = carry.readUInt32BE(0);
        if (n === 0xffff_fffe) {
          kept.frames.push("END");
          carry = carry.subarray(4);
          continue;
        }
        if (carry.length < 4 + n) break;
        kept.frames.push(hex(carry.subarray(4, 4 + n)));
        carry = carry.subarray(4 + n);
      }
      for (const f of this.#arrived.splice(0)) f();
    });
    s.on("end", () => void (kept.ended = true));
    s.on("error", () => {});
    return stream;
  }

  /// A connection given the station's next accept.
  async give(conn: number) {
    await this.until(() => this.#accepts.length > 0, `the client's accept, for connection ${conn}`);
    this.#accepts.shift()!({ conn, remote: "peer-key", alpn: "6161", via: null, paths: [], stats: {} });
  }

  /// A stream the other end opened on `conn` (`index`: its place; none: a front from before the order).
  opened(conn: number, index?: number): number {
    const stream = this.#nextStream++;
    this.#stream(conn, stream, index === undefined ? 0 : 2, index);
    return stream;
  }

  /// One the front answers itself: told so it is not waited for.
  skipped(conn: number, index: number) {
    this.#stream(conn, this.#nextStream++, 3, index).toString();
  }

  write(stream: number, bytes: Buffer) {
    const head = Buffer.alloc(4);
    head.writeUInt32BE(bytes.length);
    this.streams.get(stream)!.socket.write(Buffer.concat([head, bytes]));
  }
  end(stream: number) {
    const b = Buffer.alloc(4);
    b.writeUInt32BE(0xffff_fffe);
    this.streams.get(stream)!.socket.write(b);
  }
  /// The stream's socket ended from the front's side, as the shell ends it once the stream's receiving half is over.
  endSocket(stream: number) {
    this.streams.get(stream)!.socket.end();
  }
  fail(stream: number, words: string) {
    const b = Buffer.alloc(8);
    b.writeUInt32BE(0xffff_fffd);
    b.writeUInt32BE(Buffer.byteLength(words), 4);
    this.streams.get(stream)!.socket.write(Buffer.concat([b, Buffer.from(words)]));
  }
  close(conn: number) {
    this.#closedWaiters.get(conn)?.({ kind: "remote", reason: "app closed", text: "closed by the peer" });
    this.#closedWaiters.delete(conn);
  }

  /// The front gone (the launcher's to start again): every link ended, nothing listening.
  async drop() {
    for (const s of this.#controls.splice(0)) s.destroy();
    for (const k of this.streams.values()) k.socket.destroy();
    this.#accepts = [];
    const server = this.#server;
    this.#server = null;
    if (server !== null) await new Promise<void>((r) => server.close(() => r()));
  }
}

// (0.4 s on a Mac; its limit says a wait no bounded one above catches, never the job's)
test("the front's client: bound, its connections, streams both ways, its relays, and linked again once the front went", { skip, timeout: 30_000 }, async () => {
  const dir = fresh("front-");
  const sleeps: { ms: number; resolve: () => void }[] = [];
  let sleepAsked: (() => void) | null = null;
  const sleep = mock.method(wall, "sleep", (ms: number) => new Promise<void>((resolve) => {
    sleeps.push({ ms, resolve });
    sleepAsked?.();
  }));
  // (the TypeScript client's next wait before it links again, begun: how long it is to be; let end by wakeTs)
  const waitSleepTs = async () => {
    await within("the TypeScript client's wait before it links again", (async () => {
      while (sleeps.length === 0) await new Promise<void>((r) => (sleepAsked = r));
    })());
    return sleeps[0]!.ms;
  };
  const wakeTs = async () => {
    await waitSleepTs();
    const s = sleeps.shift()!;
    s.resolve();
    return s.ms;
  };
  const tsFront = new FakeFront(join(dir, "ts.sock"));
  const mbFront = new FakeFront(join(dir, "mb.sock"));
  let ep: Json = null;
  try {
    await tsFront.listen();
    await mbFront.listen();
    const options = { secretKey: Buffer.alloc(32, 7), alpns: [Buffer.from("stillfail/station/2"), Buffer.from("aa")], relayUrls: ["https://r1/"], discovery: false, congestion: "bbr" as const, dscp: 43 };
    ep = await withFront({} as never, tsFront.path).bind(options);
    const front = (verb: string, args: Json = {}, name = "ep") => mb().ask("front", { name, verb, args }).then(answered);
    const mbBound = await front("bind", { socket: mbFront.path, options: { secretKey: hex(options.secretKey), alpns: options.alpns.map(hex), relayUrls: options.relayUrls, discovery: false, congestion: "bbr", dscp: 43 } });
    assert.deepEqual(mbBound, { id: ep.id(), sockets: ep.sockets() });
    const both = async (what: string, ts: () => Promise<unknown> | unknown, verb: string, args: Json = {}, name = "ep") => {
      let theirs: Json;
      try {
        theirs = asJson(await within(`the TypeScript client's ${what}`, Promise.resolve().then(ts)));
      } catch (e) {
        if ((e as Error).message.startsWith("not within")) throw e;
        theirs = { error: (e as Error).message };
      }
      assert.deepEqual(await front(verb, args, name), theirs, what);
    };
    // what the endpoint is told and asks
    await both("online", () => ep.online(), "online");
    await both("routed", () => ep.route!(Buffer.from("stillfail/admin/1"), ["/tmp/serve.sock"], ["GET /admin/api/chats"]), "route", { alpn: hex(Buffer.from("stillfail/admin/1")), to: ["/tmp/serve.sock"], routes: ["GET /admin/api/chats"] });
    await both("disabled", () => ep.disabledRelays!("peer-a", ["https://r2/"], true), "disabledRelays", { peer: "peer-a", relays: ["https://r2/"], public: true });
    await both("disabled and taken back", () => ep.disabledRelays!("peer-b", [], false), "disabledRelays", { peer: "peer-b", relays: [], public: false });
    await both("a relay added", () => ep.insertRelay!("https://r3//"), "insertRelay", { url: "https://r3//" });
    await both("a relay taken out", () => ep.removeRelay!("https://r1"), "removeRelay", { url: "https://r1" });
    await both("public relays", () => ep.publicRelays!(false), "publicRelays", { on: false });
    await both("entries", () => ep.setRelayEntries!([{ entry: "e", relay: "r" }]), "setRelayEntries", { entries: [{ entry: "e", relay: "r" }] });
    await both("network changed", () => ep.networkChange!(), "networkChange");
    // (told and not answered: each front holds it before what follows is asked, or the TypeScript client's online
    // reached its front before its setCongestion, 134244003438)
    const told = (op: string) => Promise.all([tsFront, mbFront].map((f) => f.until(() => f.asks.some((a) => a.op === op), `"${op}" at the front (${f === tsFront ? "TypeScript" : "MoonBit"})`)));
    ep.keep!(["https://r1/"]);
    await front("keep", { urls: ["https://r1/"] });
    await told("keep");
    ep.setCongestion!("cubic");
    await front("setCongestion", { congestion: "cubic" });
    await told("setCongestion");
    await both("online again", () => ep.online(), "online");
    await both("linked", () => ep.linked!(), "linked");
    await both("home", () => ep.home(), "home");
    // (home triggers a background relayStatus ask as keep and setCongestion above do: wait for both fronts to receive it
    // before disabledRelays, or the MoonBit client's disabledRelays can arrive ahead of its relayStatus)
    await Promise.all([tsFront, mbFront].map((f) => f.until(() => f.asks.filter((a) => a.op === "relayStatus").length >= 2, `"relayStatus" from home at the front (${f === tsFront ? "TypeScript" : "MoonBit"})`)));
    tsFront.refuse.add("disabledRelays");
    mbFront.refuse.add("disabledRelays");
    await both("refused by a front from before", () => ep.disabledRelays!("peer-c", ["https://r9/"], false), "disabledRelays", { peer: "peer-c", relays: ["https://r9/"], public: false });
    tsFront.refuse.clear();
    mbFront.refuse.clear();
    assert.deepEqual(mbFront.asks, tsFront.asks, "asked of the front");

    // a connection the other end made, its streams in the order it opened them, and one this end opens
    const accepted = ep.accept();
    const mbAccepted = front("accept", { as: "c1" });
    await tsFront.give(1);
    await mbFront.give(1);
    const conn = (await within<Awaited<typeof accepted>>("the TypeScript client's accept", accepted))!;
    assert.deepEqual(await mbAccepted, { remote: conn.remoteId(), alpn: Buffer.from(conn.alpn()).toString("hex"), handed: (conn as { handed?: number }).handed ?? null });
    const opened = (f: FakeFront) => [f.opened(1, 1), f.opened(1, 0)];
    const [ts1, ts0] = opened(tsFront);
    const [mb1, mb0] = opened(mbFront);
    tsFront.skipped(1, 2);
    mbFront.skipped(1, 2);
    const ts3 = tsFront.opened(1, 3);
    const mb3 = mbFront.opened(1, 3);
    const tsStreams: Stream[] = [];
    for (let i = 0; i < 3; i++) tsStreams.push((await within<Awaited<ReturnType<typeof conn.acceptBi>>>(`the TypeScript client's acceptBi ${i}`, conn.acceptBi()))!);
    for (let i = 0; i < 3; i++) assert.equal(await front("acceptBi", { as: `s${i}` }, "c1"), true);
    // each read as the other end wrote it: the first taken is the one opened first
    for (const [f, ids] of [[tsFront, [ts0, ts1, ts3]], [mbFront, [mb0, mb1, mb3]]] as const) {
      ids.forEach((id, i) => f.write(id, Buffer.from(`stream ${i}`)));
      f.write(ids[0], Buffer.alloc(0));
      f.end(ids[0]);
      f.fail(ids[1], "the peer reset it");
    }
    for (let i = 0; i < 3; i++) await both(`read ${i}`, async () => hex((await tsStreams[i]!.read())!), "read", {}, `s${i}`);
    // (an empty frame gives nothing: what is read next is the end)
    await both("read past an empty frame, its end", () => tsStreams[0]!.read(), "read", {}, "s0");
    await both("read what failed it", () => tsStreams[1]!.read(), "read", {}, "s1");
    // (the front's half of the first ended after its end, as the shell's is: this end's half still open, never finished)
    tsFront.endSocket(ts0);
    mbFront.endSocket(mb0);
    // written: in frames, a large one in pieces, then finished
    const big = Buffer.alloc((1 << 20) + 5, 3);
    for (const [bytes, name] of [[Buffer.from("hello"), "s2"], [Buffer.alloc(0), "s2"], [big, "s2"]] as const) {
      await both(`write ${bytes.length}`, () => tsStreams[2]!.write(bytes), "write", { bytes: hex(bytes) }, name);
    }
    const live = await front("live");
    await both("finish", () => tsStreams[2]!.finish(), "finish", {}, "s2");
    await both("write after the finish", () => tsStreams[2]!.write(Buffer.from("x")), "write", { bytes: hex(Buffer.from("x")) }, "s2");
    // one this end opens; its stopping asked of the front
    const own = await within<Awaited<ReturnType<typeof conn.openBi>>>("the TypeScript client's openBi", conn.openBi());
    await front("openBi", { as: "o1" }, "c1");
    await both("written on one opened here", () => own.write(Buffer.from("asked")), "write", { bytes: hex(Buffer.from("asked")) }, "o1");
    // (at the front before the reset below: a reset lets go of what was not sent yet, as a QUIC stream's does, and the
    // write was answered once the client had handed it on, not once the front had it)
    const framesOf = (f: FakeFront) => [...f.streams.entries()].sort(([a], [b]) => a - b).map(([, k]) => k.frames);
    const asked = hex(Buffer.from("asked"));
    for (const f of [tsFront, mbFront]) await f.until(() => framesOf(f).flat().includes(asked), `"asked" at the front (${f === tsFront ? "TypeScript" : "MoonBit"})`);
    await both("stopped", () => own.stopped(), "stopped", {}, "o1");
    await both("reset", () => own.reset(5), "reset", { code: 5 }, "o1");
    await both("read once reset", () => own.read(), "read", {}, "o1");
    await both("answers", () => conn.answers!(100), "answers", { within: 100 }, "c1");
    await both("via", () => conn.via!(), "via", {}, "c1");
    await both("not closed yet", () => conn.isClosed(), "isClosed", {}, "c1");
    // what reached the front of each stream (once the finished stream's end is there: all written before it is)
    const there = (f: FakeFront) => f.until(() => framesOf(f).flat().includes("END"), "the finished stream's end at the front");
    await there(tsFront);
    await there(mbFront);
    assert.deepEqual(framesOf(mbFront), framesOf(tsFront), "what reached the front");
    // the finished stream's socket let go once the front ended its half too (as the front's Node socket does once it
    // read the end), as Node lets a half-open socket go once both halves are over: the shell keeps one until it is
    // told to close it, and 61k of them filled a station (2026-11-19)
    await within("the finished stream's socket let go", front("live", { fewerThan: live }));
    // the connection closed at the other end
    const open = await front("live");
    tsFront.close(1);
    mbFront.close(1);
    await both("closed", () => conn.closed(), "closed", {}, "c1");
    // (its streams' sockets let go with it, the first's too, whose read side ended before: 61k of those filled a
    // station, 2026-11-19)
    await within("the closed connection's sockets let go", front("live", { fewerThan: open - 1 }));
    await both("its reason", () => conn.closeReason!(), "closeReason", {}, "c1");
    await both("a stream of it after", () => conn.acceptBi(), "acceptBi", { as: "after" }, "c1");

    // the front gone: linked again, the routes and disabled relays given again first
    await tsFront.drop();
    await mbFront.drop();
    // (every socket of the link gone let go, its control socket too: the shell keeps one until it is told to close it)
    await within("every socket of the link gone let go", front("live", { fewerThan: 1 }));
    // (what the MoonBit client said, kept: "logs" gives each once)
    const mbLogs: Json[] = [];
    const takeMbLogs = async () => (mbLogs.push(...(await front("logs"))), mbLogs);
    // (its try before the wait of `ms` failed: it says so as it begins that wait, nothing between)
    const mbFailedBefore = (ms: number) => within(`the MoonBit client's try failed, its ${ms} ms wait begun`, (async () => {
      while (!(await takeMbLogs()).some((l) => l.words === "the front not reached" && l.with?.again === `${ms} ms`)) {
        await new Promise((r) => setTimeout(r, 5));
      }
    })());
    assert.equal(await wakeTs(), 250);
    assert.equal(await front("wake"), 250);
    // (nothing listens yet: the next try waits twice as long)
    assert.equal(await wakeTs(), 500);
    assert.equal(await front("wake"), 500);
    // (each 500 ms try failed before the front listens again: else the one slower to try links on it, and is never
    // to wait the 1000 ms woken below; the MoonBit client did, its wake waited for good, #7026's check-station (4))
    assert.equal(await waitSleepTs(), 1000);
    await mbFailedBefore(1000);
    await tsFront.listen();
    await mbFront.listen();
    const before = { ts: tsFront.asks.length, mb: mbFront.asks.length };
    assert.equal(await wakeTs(), 1000);
    assert.equal(await front("wake"), 1000);
    await both("online, once linked again", () => ep.online(), "online");
    assert.deepEqual(mbFront.asks.slice(before.mb), tsFront.asks.slice(before.ts), "asked of the front linked to again");
    await both("linked again", () => ep.linked!(), "linked");
    // (why the socket was not reached is the system's words: Node's and the shell's differ)
    const systems = (ls: Json[]) => ls.map((l) => (l.words === "the front not reached" ? { ...l, with: { ...l.with, error: "<the system's words>" } } : l));
    assert.deepEqual(systems(await takeMbLogs()), systems(said("mesh").map((l) => ({ ...l, at: "mesh" }))), "said of it");
    await front("close");
  } finally {
    await ep?.close();
    sleep.mock.restore();
    await tsFront.drop();
    await mbFront.drop();
  }
});

// ── the served programs' keeper ───────────────────────────────────────────────────────────────────────────────────

/// The TypeScript's `Served` with programs, time and answers of the test's (as harness_served.mbt's world): every message
/// each program is told and every call made, kept.
class ServedWorldTs {
  processes: { told: Json[]; emit: (event: string, ...a: unknown[]) => void }[] = [];
  calls: Json[] = [];
  now = 1_000_000;
  due: { at: number; f: () => void; off: boolean }[] = [];
  relays = new Map<number, { send: (t: string) => void; ended: () => void }>();
  pieces = new Map<number, { queue: (string | null)[]; waiting: ((v: string | null) => void) | null }>();
  claims = 0;
  started: Json = null;
  served: Served;

  constructor(data: string) {
    const w = this;
    this.served = new Served("stillfail-reader", data, async (viewer, head, body) => {
      w.calls.push(["answer", viewer, head, body.toString()]);
      if (typeof head?.fail === "string") throw new Error(head.fail);
      return { status: 200, headers: { x: "y" }, body: Buffer.from("answered") };
    }, (viewer, build) => void w.calls.push(["built", viewer, build]), async (viewer, head, body): Promise<any> => {
      w.calls.push(["stream", viewer, head, body.toString()]);
      const n = head.n;
      if (head.kind === "fail") throw new Error("no stream here");
      if (head.kind === "whole") return { status: 200, headers: {}, body: Buffer.from(head.text ?? "") };
      if (head.kind === "relay") {
        const body = { relay: (send: (t: string) => void, ended: () => void) => void w.relays.set(n, { send, ended }), return: async () => (w.calls.push(["relay stopped", n]), { done: true, value: undefined }), [Symbol.asyncIterator]() { return this; }, next: async () => ({ done: true, value: undefined }) };
        return { status: 200, headers: { "content-type": "text/event-stream" }, body: body as never };
      }
      const kept = { queue: [] as (string | null)[], waiting: null as ((v: string | null) => void) | null };
      w.pieces.set(n, kept);
      const it = {
        next: async () => {
          const v = kept.queue.length > 0 ? kept.queue.shift()! : await new Promise<string | null>((r) => (kept.waiting = r));
          return v === null ? { done: true, value: undefined } : { done: false, value: Buffer.from(v) };
        },
        return: async () => (w.calls.push(["pieces stopped", n]), { done: true, value: undefined }),
        [Symbol.asyncIterator]() { return this; },
      };
      return { status: 200, headers: {}, body: it as never };
    }, {
      spawn: (binary, args) => {
        const index = w.processes.length;
        w.calls.push(["spawn", binary, args]);
        const p = new Served1(args[args.indexOf("--serve") + 1]!);
        const kept = { told: p.told, emit: (event: string, ...a: unknown[]) => void p.emit(event, ...a) };
        p.terminate = async () => {
          w.calls.push(["terminate", index]);
          p.emit("exit", 0);
          return 0;
        };
        w.processes.push(kept);
        return p;
      },
      now: () => w.now,
      after: (ms, f) => {
        const d = { at: w.now + ms, f, off: false };
        w.due.push(d);
        return () => void (d.off = true);
      },
    });
    this.served.onRoutes = (paths) => void w.calls.push(["routes", paths]);
    this.served.changed = (changes, titled) => void w.calls.push(["changed", changes, titled]);
    this.served.says = {
      claim: async (viewer, path, key, lang) => {
        w.calls.push(["claim", viewer, path, key, lang]);
        if (path === "/kept") return { kept: { status: 200, headers: {}, body: Buffer.from('{"kept":1}') } };
        if (path === "/refused") return { refused: { status: 409, headers: {}, body: Buffer.from("no") } };
        if (path === "/throw") throw new Error("the store is busy");
        const by = `${path}#${w.claims++}`;
        return { ts: by, settle: (answer) => void w.calls.push(["settled", by, answer === null ? null : { status: answer.status, headers: answer.headers, text: answer.body.toString() }]) };
      },
      said: (thread, n, text, row) => void w.calls.push(["said", thread, n, text, row]),
    };
  }

  step(a: Json) {
    switch (a.op) {
      case "start": void this.served.start().then((live) => (this.started = live), (e) => (this.started = { error: (e as Error).message })); break;
      case "say": this.processes[a.p]?.emit("message", a.said); break;
      case "exit": this.processes[a.p]?.emit("exit", a.code); break;
      case "pass": {
        this.now += a.ms;
        const ready = this.due.filter((d) => d.at <= this.now).sort((x, y) => x.at - y.at);
        this.due = this.due.filter((d) => d.at > this.now);
        for (const d of ready) if (!d.off) d.f();
        break;
      }
      case "viewer": this.served.viewer(a.conn, a.viewer ?? null, a.moved === true, a.floor ?? null); break;
      case "relaySend": this.relays.get(a.n)?.send(a.text); break;
      case "relayEnd": this.relays.get(a.n)?.ended(); break;
      case "relaySends": for (const [n, text] of a.sends) this.relays.get(n)?.send(text); break;
      case "piece": {
        const k = this.pieces.get(a.n);
        if (!k) break;
        const v = a.text ?? null;
        if (k.waiting) {
          const r = k.waiting;
          k.waiting = null;
          r(v);
        } else k.queue.push(v);
        break;
      }
      case "close": void this.served.close(); break;
    }
  }

  told() {
    const out = {
      told: this.processes.map((p) => p.told.splice(0).map((m) => asJson(m.set !== undefined ? { ...m, set: "<set>" } : m))),
      calls: asJson(this.calls.splice(0)), logs: said("served").map((l) => ({ ...l, at: "served" })), started: asJson(this.started),
    };
    return out;
  }
}

test("the served programs as Served keeps them: started, told, given back their requests, their streams and messages, started again", { skip }, async () => {
  const W = 1_700_000_000_000;
  const now = mock.method(wall, "now", () => W);
  const data = fresh("served-runtime-");
  try {
    const ts = new ServedWorldTs(data);
    await make("Served", "served", { binary: "stillfail-reader", data, pid: process.pid, sep: "/", wall: W, now: ts.now });
    const step = async (a: Json, what: string) => {
      ts.step(a);
      await settled();
      const ours = await ask("served", "step", a);
      assert.deepEqual(ours, ts.told(), `${what}: ${JSON.stringify(a)}`);
    };
    const path = (i: number) => join(data, "run", `serve-${process.pid}-${i}.sock`);
    const listen = (p: number, i: number) => ({ op: "say", p, said: { listening: path(i) } });
    const alice = { email: "ada@x", name: "Ada" };
    const steps: [string, Json][] = [
      ["started", { op: "start" }], ["one listens", listen(0, 0)], ["a member told before the second", { op: "viewer", conn: 1, viewer: alice }],
      ["the second listens", listen(1, 1)], ["the same again", { op: "viewer", conn: 1, viewer: alice }], ["moved", { op: "viewer", conn: 1, viewer: alice, moved: true, floor: 9144 }],
      ["renamed", { op: "viewer", conn: 1, viewer: { email: "ada@x", name: "Ada L" } }], ["another", { op: "viewer", conn: 2, viewer: { email: "bob@x" } }],
      ["a build", { op: "say", p: 0, said: { build: { conn: 1, build: 9200 } } }], ["a build of none", { op: "say", p: 0, said: { build: { conn: "2", build: "x" } } }],
      ["a build of a gone", { op: "say", p: 0, said: { build: { conn: 7, build: 1 } } }],
      ["given back", { op: "say", p: 0, said: { fallback: 1, conn: 1, head: { path: "/a" }, body: "{}" } }],
      ["given back, failing", { op: "say", p: 1, said: { fallback: 2, conn: 1, head: { fail: "boom" } } }],
      ["given back, gone", { op: "say", p: 0, said: { fallback: 3, conn: 9, head: {} } }],
      ["a stream, whole", { op: "say", p: 0, said: { fallback: 4, stream: true, conn: 1, head: { kind: "whole", text: "hi" } } }],
      ["a stream, empty", { op: "say", p: 0, said: { fallback: 5, stream: true, conn: 1, head: { kind: "whole" } } }],
      ["a stream that fails", { op: "say", p: 0, said: { fallback: 6, stream: true, conn: 1, head: { kind: "fail" } } }],
      ["a stream of a gone", { op: "say", p: 0, said: { fallback: 7, stream: true, conn: 5, head: { kind: "whole" } } }],
      ["relayed", { op: "say", p: 0, said: { fallback: 10, stream: true, conn: 1, head: { kind: "relay", n: 10 } } }],
      ["relayed too", { op: "say", p: 0, said: { fallback: 11, stream: true, conn: 2, head: { kind: "relay", n: 11 } } }],
      ["a piece", { op: "relaySend", n: 10, text: "a" }], ["its end", { op: "relayEnd", n: 11 }],
      ["in pieces", { op: "say", p: 1, said: { fallback: 12, stream: true, conn: 1, head: { kind: "pieces", n: 12 } } }],
      ["a piece of it", { op: "piece", n: 12, text: "p1" }], ["another", { op: "piece", n: 12, text: "p2" }], ["its end", { op: "piece", n: 12 }],
      ["in pieces, stopped", { op: "say", p: 1, said: { fallback: 13, stream: true, conn: 1, head: { kind: "pieces", n: 13 } } }],
      ["stopped", { op: "say", p: 1, said: { stop: 13 } }], ["a piece after", { op: "piece", n: 13, text: "late" }],
      ["a relay stopped", { op: "say", p: 0, said: { stop: 10 } }], ["sent after it stopped", { op: "relaySend", n: 10, text: "z" }], ["its end after", { op: "relayEnd", n: 10 }],
      ["claimed", { op: "say", p: 0, said: { claim: 0, conn: 1, path: "/m", key: "k", lang: "en" } }],
      ["claimed by the other", { op: "say", p: 1, said: { claim: 0, conn: 1, path: "/n" } }],
      ["kept", { op: "say", p: 0, said: { claim: 1, conn: 1, path: "/kept" } }], ["refused", { op: "say", p: 0, said: { claim: 2, conn: 1, path: "/refused" } }],
      ["failed", { op: "say", p: 0, said: { claim: 3, conn: 1, path: "/throw" } }], ["of none", { op: "say", p: 0, said: { claim: 4, conn: 8, path: "/m" } }],
      ["said", { op: "say", p: 0, said: { said: { thread: 3, n: 2, text: "hi", row: { a: 1 } }, of: 0, answer: { status: 201, headers: { h: "v" }, text: "ok" } } }],
      ["said with nothing written", { op: "say", p: 1, said: { said: null, of: 0 } }], ["said again", { op: "say", p: 1, said: { said: null, of: 0 } }],
      ["changed", { op: "say", p: 0, said: { changes: [{ t: 1 }], titled: [4] } }], ["changed, no titles", { op: "say", p: 0, said: { changes: [], titled: "x" } }],
      ["a claim left", { op: "say", p: 0, said: { claim: 5, conn: 1, path: "/left" } }],
      ["two relays at once", { op: "say", p: 1, said: { fallback: 20, stream: true, conn: 1, head: { kind: "relay", n: 20 } } }],
      ["and its twin", { op: "say", p: 1, said: { fallback: 21, stream: true, conn: 1, head: { kind: "relay", n: 21 } } }],
      ["one piece to both, in one turn", { op: "relaySends", sends: [[20, "same"], [21, "same"], [20, "other"], [21, "same"]] }],
      ["one ended", { op: "exit", p: 0, code: 3 }], ["started again at once, listening", listen(2, 0)],
      ["one ended soon", { op: "exit", p: 2, code: 4 }], ["a second later", { op: "pass", ms: 999 }], ["now", { op: "pass", ms: 1 }], ["listening", listen(3, 0)],
      ["a member gone", { op: "viewer", conn: 2, viewer: null }], ["closed", { op: "close" }], ["ended after", { op: "exit", p: 1, code: 0 }],
    ];
    for (const [what, a] of steps) {
      if (what === "one ended") ts.now += SERVED_STEADY_MS;
      if (what === "one ended") await mb().ask("do", { on: "served", method: "step", args: { op: "pass", ms: SERVED_STEADY_MS } });
      await step(a, what);
    }
  } finally {
    now.mock.restore();
  }
});
