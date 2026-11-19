// The cloud's network in MoonBit (station/mb src/cloud_net: `stillfail-reader-harness --builder harness-cloud-net`) held to the
// TypeScript it replaces on the same inputs: the URLs as `new URL` reads them, the relays' and marks' records, what
// is refused and in what words, which of two is kept, the relays each station is kept on and each peer is held to, a
// dial's candidates on one clock, two stations brought level through failures and retries, the plane's frames and what
// they make of cloud.json (the rig ↔ whole agreement among them), another station on this key, and the ways told on a
// socket. Each case is given both whole; their outcomes must be the same.
import assert from "node:assert/strict";
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { EventEmitter } from "node:events";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { after, mock, test } from "node:test";
import { WebSocketServer } from "ws";
import { sha256hex } from "../src/cloud/key.ts";
import { Replaced, applyState, waysTeller } from "../src/cloud/presence.ts";
import { PROVIDERS, providerOf, signedHeaders, specOf } from "../src/cloud/provider.ts";
import { Cloud, isRevocation, joinedOf, rigsOf, waysSaidOf, writeState } from "../src/cloud/state.ts";
import { CLOUD_ORIGIN, cloudEntry, dialCloud, type DialIO } from "../src/cloud/transport.ts";
import { failureText } from "../src/cloud/presence.ts";
import { PeerRelays, peerDisabled } from "../src/mesh/peer-relays.ts";
import { oursOff, stationAddr, wantedRelays } from "../src/mesh/relays.ts";
import { StationMarks, answerMarks, followMarks, markEmoji, markIcon, markName, markOf } from "../src/mesh/station-marks.ts";
import { otlpBody } from "../src/mesh/traces.ts";
import { Ways, addRelay, answerWays, followWays, offRelays, recordOf, relayUrl, removeRelay, sameUrl, setRelays, setWay, stillFails, waysOf, workspaceRelays } from "../src/mesh/ways.ts";
import { wall } from "../src/ops/fibers.ts";
import { mbHarnessBinary } from "./mb-harness.ts";

const binary = mbHarnessBinary();
const skip = binary === null ? "the tests' MoonBit program (stillfail-reader-harness) is not built here" : false;

const dirs: string[] = [];
const fresh = (what: string) => {
  const dir = mkdtempSync(join(tmpdir(), `cloud-net-${what}-`));
  dirs.push(dir);
  return dir;
};

let program: { child: ChildProcessWithoutNullStreams; next: (line: string) => Promise<any> } | null = null;
/// The program, started once: a case a line, its answer a line.
function harness() {
  if (program !== null) return program;
  const shell = fresh("shell");
  const child = spawn(binary!, ["--builder", "harness-cloud-net", "--shell-dir", shell], { stdio: ["pipe", "pipe", "pipe"] });
  const waiting: ((line: string) => void)[] = [];
  createInterface({ input: child.stdout }).on("line", (line) => waiting.shift()?.(line));
  let stderr = "";
  child.stderr.on("data", (d) => (stderr += d));
  child.on("exit", (code) => { for (const w of waiting.splice(0)) w(JSON.stringify({ error: `the program ended (${code}): ${stderr}` })); });
  program = {
    child,
    next: (line) => new Promise((resolve) => {
      waiting.push((answer) => resolve(JSON.parse(answer)));
      child.stdin.write(`${line}\n`);
    }),
  };
  return program;
}
after(() => {
  program?.child.stdin.end();
  for (const dir of dirs) rmSync(dir, { recursive: true, force: true });
});

/// What MoonBit says of `c` (its `ok`, or the words it failed with).
async function mb(c: unknown): Promise<any> {
  const answer = await harness().next(JSON.stringify(c));
  if ("error" in answer) throw new Error(`MoonBit: ${answer.error}`);
  return answer.ok;
}

/// A JSON round trip: what both sides are compared as.
const plain = (v: unknown) => (v === undefined ? null : JSON.parse(JSON.stringify(v)));
/// An outcome as the harness says it: `{ok}` or `{error}` with the words.
const outcome = (f: () => unknown) => {
  try {
    return { ok: plain(f()) };
  } catch (e) {
    return { error: (e as Error).message };
  }
};

const A = "a".repeat(64);
const B = "b".repeat(64);
const C = "c".repeat(64);
const WS = "w1";
const W2 = "w2";
const OURS = ["https://r1.still.fail", "https://r2.still.fail"];

/// A cloud.json as a station of `me` keeps it, in WS with `peers`, joined to `joined`.
function stateOf(me: string, more: Record<string, unknown> = {}): any {
  return {
    origin: "https://app.still.fail", station: me, workspace: WS, workspace_name: "W1", name: "here",
    relay_url: OURS[0], relay_urls: [...OURS, "https://theirs.example"], stillfail_relays: OURS, grant_keys: {},
    peers: [{ id: me === A ? B : A }], revocations: [], ...more,
  };
}

/// A station's Cloud on that state, and the state as it was read (what the program is given).
function cloudOf(state: any, kept?: { ways?: string; marks?: string }) {
  const data = fresh("station");
  writeState(data, state);
  mkdirSync(join(data, "mesh"), { recursive: true });
  if (kept?.ways !== undefined) writeFileSync(join(data, "mesh", "ways.json"), kept.ways);
  if (kept?.marks !== undefined) writeFileSync(join(data, "mesh", "station-marks.json"), kept.marks);
  const cloud = new Cloud(data, false);
  return { cloud, data, state: plain(cloud.state) };
}

// ── the URLs and the records, one function at a time ──

const URLS = [
  "https://relay.example.com", "https://Relay.Example.COM/", "https://relay.example.com:443/", "https://relay.example.com:8443//",
  "http://localhost:3000/x/../y/./z", "HTTPS://a.b/%7e?q=1#f", "https://user:pw@host/", "https://host/?", "https://host/#",
  "https://0x7f.1/", "https://127.1/", "https://[::1]:443/", "https://[2001:db8:0:0:0:0:2:1]/", "https://[::ffff:192.168.1.1]/",
  "https://[1:0:0:2:0:0:0:3]/", "https://[::]/", " https://trim.me/  ", "https://ta\tb.c/", "https:\\\\back.slash\\path",
  "https:noslash.com", "https://例え.jp/パス", "https://bücher.de/", "https://xn--r8jz45g.jp/", "https://host/a b",
  "https://host/a%20b?x y#z w", "wss://app.still.fail/v1/stations/connect", "lan", "ours", "tailnet", "direct", "",
  "mailto:x@y", "foo://Host/Path", "foo:bar baz", "https://", "https://:443", "http://a:99999/", "https://host/%2e%2E/x",
  "https://host/a/%2e./b", "file:///tmp/x", "file://localhost/etc", "https://a..b/", "https://host:/", "https://ho%73t/",
  "https://host/^`{}", "https://host/?a'b\"c", "https://exa mple.com/", "https://h/p?q#f#g", "data:text/plain,hi",
  "https://1.2.3.4.5/", "https://256.0.0.1/", "https://09.1/", "https://foo.0x/", "https://h/é", "https://h:0/",
  "https://h.example:65535/x", "ws://h:80/", "wss://h:443/", "ftp://h:21/", "https://h/%zz", "https://%41.com/",
];

/// What `new URL` says of one, as the harness says it.
const urlOf = (raw: string) => {
  try {
    const u = new URL(raw);
    return [u.href, u.origin, u.pathname, u.search, u.hash];
  } catch {
    return null;
  }
};

test("URLs read as `new URL` reads them", { skip }, async () => {
  for (const raw of URLS) assert.deepEqual(await mb({ op: "pure", fn: "url", args: [raw] }), urlOf(raw), raw);
});

const RELAYS: unknown[] = [
  "https://relay.example", " https://relay.example/// ", "http://relay.example", "https://u:p@relay.example", "https://relay.example/?a",
  "https://relay.example/#x", "https://RELAY.example:443/path/", "ftp://relay.example", "not a url", 7, null, "https://[::1]:8443",
  "https://relay.example/?", "　https://relay.example ",
];

test("a relay's URL, its compared form, and a record as a peer says it", { skip }, async () => {
  for (const raw of RELAYS) {
    for (const insecure of [false, true]) assert.deepEqual(await mb({ op: "pure", fn: "relayUrl", args: [raw, insecure] }), relayUrl(raw, insecure), `${raw} ${insecure}`);
    if (typeof raw === "string") assert.equal(await mb({ op: "pure", fn: "sameUrl", args: [raw] }), sameUrl(raw), raw);
  }
  const records: unknown[] = [
    null, 3, {}, { relays: [], at: 1, station: "s" }, { relays: [], at: -1, station: "s" }, { relays: [], at: 1.5, station: "s" },
    { relays: [], at: 2 ** 53, station: "s" }, { relays: "x", at: 1, station: "s" }, { relays: [], at: 1 },
    { relays: ["https://a.example/", { url: "https://a.example" }, { url: "https://b.example", by: "x".repeat(300) }, { url: "http://c.example", by: "" }, { url: "ftp://d" }, "https://e.example", "https://f.example", "https://g.example"], off: ["lan", "lan", 3, "ours", "https://a.example"], at: 10, station: "s" },
    { relays: [{ url: "https://h.example", by: "上海中继 chat 🚀" }], at: 0, station: "" },
  ];
  for (const raw of records) assert.deepEqual(await mb({ op: "pure", fn: "recordOf", args: [raw] }), plain(recordOf(raw)), JSON.stringify(raw));
});

test("a mark's name, emoji, icon and record as the cloud takes them", { skip }, async () => {
  const names: unknown[] = ["  my   station \t here ", "", "   ", "x".repeat(80), "x".repeat(81), "🚀".repeat(40), "🚀".repeat(41), 3, null, "a　b c", "line\nbreak"];
  for (const raw of names) assert.equal(await mb({ op: "pure", fn: "markName", args: [raw] }), markName(raw), String(raw));
  const emojis: unknown[] = ["🚀", " 🚀x", "x🚀", "", null, 4, "👍🏽", "👨‍👩‍👧‍👦", "🇨🇳", "🇨🇳🇯🇵", "1️⃣", "©", "™️", "a", "   ", "🏴󠁧󠁢󠁳󠁣󠁴󠁿", "❤️‍🔥", "☺"];
  for (const raw of emojis) assert.equal(await mb({ op: "pure", fn: "markEmoji", args: [raw] }), markEmoji(raw), String(raw));
  const icons: unknown[] = [
    "", null, 5, "glyph:rocket", "glyph:rocket:blue", "glyph:Rocket", "glyph:", "glyph:a:b:c", `glyph:${"a".repeat(41)}`, `glyph:a:${"b".repeat(17)}`,
    `https://app.still.fail/v1/icons/${"0".repeat(32)}.png`, `https://App.Still.Fail/v1/icons/${"a".repeat(32)}.webp`, `https://x.example/v1/icons/${"a".repeat(32)}.gif`,
    `http://x.example/v1/icons/${"a".repeat(32)}.png`, `https://x.example/v1/icons/${"a".repeat(32)}.svg`, `https://x.example/v1/icons/${"A".repeat(32)}.png`,
    `https://x.example/v1/icons/${"a".repeat(32)}.png?x`, `https://u@x.example/v1/icons/${"a".repeat(32)}.png`, `https://x.example/v1/icons/${"a".repeat(31)}.png`,
    `https://x.example/v1/x/../icons/${"a".repeat(32)}.jpeg`, `https://x.example/${"a".repeat(300)}`,
  ];
  for (const raw of icons) assert.equal(await mb({ op: "pure", fn: "markIcon", args: [raw] }), markIcon(raw), String(raw));
  const records: unknown[] = [
    { name: "s", at: 1 }, { name: "s", at: 0 }, { name: "s", emoji: "🚀", icon: "glyph:x", at: 5 }, { name: " ", at: 1 }, { name: "s", emoji: "x", at: 1 },
    { name: "s", emoji: null, icon: null, at: 2 }, { name: "s", at: 1.5 }, null, [], { name: "s", icon: "data:image/png", at: 1 },
  ];
  for (const raw of records) assert.deepEqual(await mb({ op: "pure", fn: "markOf", args: [raw] }), plain(markOf(raw)), JSON.stringify(raw));
});

test("the providers, their signed headers, a cloudEntry, what fails says and the state's lists", { skip }, async () => {
  for (const raw of [undefined, "comma", "stillfail", "Comma", 3]) assert.equal(await mb({ op: "pure", fn: "providerOf", args: [raw ?? null] }), providerOf(raw));
  for (const p of PROVIDERS) {
    const s = specOf(p);
    assert.deepEqual(await mb({ op: "pure", fn: "specOf", args: [p] }), plain({ ...s, releaseBase: s.releaseBase("https://o.example") }), p);
  }
  for (const [prefixes, extra] of [[["stillfail"], {}], [["comma"], { version: "1.2" }], [["stillfail", "comma"], { version: "v" }], [[], {}]] as const) {
    const sign = (p: string) => `signed:${p}:${A}:1700000000`;
    assert.deepEqual(await mb({ op: "pure", fn: "signedHeaders", args: [prefixes, A, 1700000000, extra] }), signedHeaders(prefixes, A, 1700000000, sign, extra), JSON.stringify(prefixes));
  }
  const entries: unknown[] = [
    {}, { cloudEntry: { origin: CLOUD_ORIGIN, host: "e.example", port: 24443 } }, { cloudEntry: { origin: "https://x", host: "e", port: 1 } },
    { cloudEntry: { origin: CLOUD_ORIGIN, host: "", port: 1 } }, { cloudEntry: { origin: CLOUD_ORIGIN, host: "e", port: 65536 } },
    { cloudEntry: { origin: CLOUD_ORIGIN, host: "e", port: 1.5 } }, { cloudEntry: null }, { cloudEntry: { origin: CLOUD_ORIGIN, host: "e", port: "1" } },
  ];
  for (const raw of entries) {
    const ts = outcome(() => cloudEntry(raw));
    let ours: any;
    try { ours = { ok: await mb({ op: "pure", fn: "cloudEntry", args: [raw] }) }; } catch (e) { ours = { error: (e as Error).message.replace(/^MoonBit: /, "") }; }
    assert.deepEqual(ours, ts, JSON.stringify(raw));
  }
  for (const [message, errors] of [["cloud TLS connections failed", ["direct refused", "", "entry reset"]], ["timed out", []], ["", ["", ""]]] as [string, string[]][]) {
    const e = errors.length > 0 ? new AggregateError(errors.map((m) => new Error(m)), message) : new Error(message);
    assert.equal(await mb({ op: "pure", fn: "failureText", args: [message, errors] }), failureText(e));
  }
  for (const text of ["", "abc", "{\"notices\":[]}", "é🚀中".repeat(50)]) assert.equal(await mb({ op: "pure", fn: "sha256", args: [text] }), sha256hex(text));
  const rigs = [{ id: B, owner: "u", name: "r", version: "1" }, { id: "x", owner: "u" }, { id: C, owner: "" }, { id: C, owner: "v", owner_email: 3 }, null];
  assert.deepEqual(await mb({ op: "pure", fn: "rigsOf", args: [rigs] }), plain(rigsOf(rigs)));
  const joined = [{ workspace: "w2", peers: [{ id: B }], revocations: [{ kind: "d", id: "1", at: 2 }, { kind: "d", id: 1, at: 2 }], locked: true, rigs, ways: { relays: ["x", 3], off: "y" } }, { workspace: "" }, { workspace: "w3", workspace_name: 7, rigs: [] }];
  assert.deepEqual(await mb({ op: "pure", fn: "joinedOf", args: [joined] }), plain(joinedOf(joined)));
  for (const w of [null, { relays: ["a", 1], off: ["b", null] }, { relays: "a" }, { off: [] }]) assert.deepEqual(await mb({ op: "pure", fn: "waysSaidOf", args: [w] }), plain(waysSaidOf(w)));
  for (const r of [{ kind: "d", id: "x", at: 0 }, { kind: "d", id: "x", at: -1 }, { kind: "d", id: "x", at: 1.5 }, { kind: "d", at: 1 }, null]) assert.equal(await mb({ op: "pure", fn: "isRevocation", args: [r] }), isRevocation(r));
  const spans = [{ name: "a", attributes: [] }];
  assert.equal(await mb({ op: "pure", fn: "otlpBody", args: [A, spans] }), otlpBody(A, spans));
  const resource: [string, string][] = [["service.version", "0.1.1"], ["os.type", "linux"], ["host.arch", ""], ["", "x"], ["process.runtime.name", "moonbit"]];
  assert.equal(await mb({ op: "pure", fn: "otlpBody", args: [A, spans, resource] }), otlpBody(A, spans, resource));
});

// ── the ways and the marks, step by step ──

/// A ways step done by the TypeScript, as the harness does it.
function waysStep(ways: Ways, cloud: Cloud, step: any): unknown {
  switch (step.do) {
    case "add": return addRelay(ways, step.ws, step.url, step.by ?? null);
    case "remove": return removeRelay(ways, step.ws, step.url);
    case "set": return setRelays(ways, step.ws, step.urls, step.by ?? null);
    case "setWay": return setWay(ways, step.ws, step.way, step.on === true);
    case "take": { const r = recordOf(step.record); return r === null ? null : ways.take(step.ws, r); }
    case "answer": return answerWays(ways, step.request, step.ws);
    case "state": cloud.update((st) => { for (const k of Object.keys(st)) delete (st as any)[k]; Object.assign(st, step.state); }); return null;
  }
  throw new Error(`no such step: ${step.do}`);
}

/// What the TypeScript's ways come to, as the harness's summary says it.
async function waysSummary(cloud: Cloud, ways: Ways, peers: string[]) {
  const workspaces: Record<string, unknown> = {};
  for (const m of cloud.memberships()) workspaces[m.workspace] = { view: ways.view(m.workspace), record: ways.record(m.workspace), on: workspaceRelays(ways, m.workspace), off: offRelays(ways, m.workspace) };
  const addr: Record<string, unknown> = {};
  const held: Record<string, unknown> = {};
  const endpoint = { disabledRelays: async () => {} } as any;
  const holding = new PeerRelays(endpoint, cloud);
  for (const p of peers) {
    addr[p] = stationAddr(cloud, p);
    await holding.hold(p);
    held[p] = { disabled: peerDisabled(cloud, p), key: holding.heldOf(p) ?? "" };
  }
  holding.close();
  return plain({ workspaces, stillFails: stillFails(cloud), relays: ways.relays(), wanted: wantedRelays(cloud), oursOff: oursOff(cloud), addr, held });
}

async function sameWays(name: string, state: any, steps: any[], kept?: object) {
  const text = kept === undefined ? undefined : JSON.stringify(kept);
  const { cloud, state: read } = cloudOf(state, { ways: text });
  const ways = waysOf(cloud);
  const told: string[] = [];
  const stop = ways.listen((ws) => told.push(ws));
  const steps2: unknown[] = [];
  for (const step of steps) {
    if (typeof step.now === "number") mock.method(wall, "now", () => step.now);
    steps2.push(outcome(() => waysStep(ways, cloud, step)));
  }
  stop();
  const peers = [A, B, C];
  await ways.written();
  let file: unknown = null;
  try { file = JSON.parse(readFileSync(join(cloud.data, "mesh", "ways.json"), "utf8")); } catch {}
  const ts = { steps: steps2, told, summary: await waysSummary(cloud, ways, peers), file };
  const ours = await mb({ op: "ways", state: read, kept: text ?? null, now: 0, steps, peers });
  assert.deepEqual(ours, ts, name);
  mock.restoreAll();
  return ts;
}

test("the ways: added, removed, set, turned off and on, refused in the same words, the newer kept", { skip }, async () => {
  const urls = ["https://own1.example", "https://own2.example/", "https://own3.example", "https://own4.example", "https://own5.example"];
  await sameWays("adding to the fifth and taking out", stateOf(A), [
    { now: 1000, do: "add", ws: WS, url: urls[0], by: "an agent" },
    { now: 1000, do: "add", ws: WS, url: urls[1], by: null },
    { now: 999, do: "add", ws: WS, url: "https://own1.example/", by: "again" },
    { now: 2000, do: "add", ws: WS, url: urls[2] },
    { now: 2000, do: "add", ws: WS, url: urls[3] },
    { now: 3000, do: "add", ws: WS, url: urls[4] },
    { now: 3000, do: "add", ws: WS, url: "https://r1.still.fail/" },
    { now: 3000, do: "add", ws: WS, url: "ftp://x" },
    { now: 3000, do: "add", ws: WS, url: "http://plain.example" },
    { now: 3500, do: "remove", ws: WS, url: "https://own2.example" },
    { now: 3500, do: "remove", ws: WS, url: "https://nowhere.example" },
    { now: 4000, do: "add", ws: W2, url: urls[4] },
  ]);
  await sameWays("ways off and on, the last relay kept on, ours on taking back what apps of before turned off", stateOf(A), [
    { now: 10, do: "add", ws: WS, url: "https://own.example" },
    { now: 20, do: "setWay", ws: WS, way: "lan", on: false },
    { now: 30, do: "setWay", ws: WS, way: "https://r1.still.fail", on: false },
    { now: 40, do: "setWay", ws: WS, way: "ours", on: false },
    { now: 50, do: "setWay", ws: WS, way: "https://own.example", on: false },
    { now: 60, do: "setWay", ws: WS, way: "nonesuch", on: false },
    { now: 70, do: "setWay", ws: WS, way: "ours", on: true },
    { now: 80, do: "setWay", ws: WS, way: "tailnet", on: false },
    { now: 90, do: "setWay", ws: WS, way: "ours", on: false },
    { now: 100, do: "remove", ws: WS, url: "https://own.example" },
  ]);
  await sameWays("the whole list set, who added each kept, a sixth refused", stateOf(A), [
    { now: 5, do: "add", ws: WS, url: "https://a.example", by: "first" },
    { now: 6, do: "setWay", ws: WS, way: "https://a.example", on: false },
    { now: 7, do: "set", ws: WS, urls: ["https://a.example/", "https://b.example", "https://r2.still.fail", "https://b.example/"], by: "the app" },
    { now: 8, do: "set", ws: WS, urls: ["https://c.example"], by: "" },
    { now: 9, do: "set", ws: WS, urls: ["1", "2"] },
    { now: 9, do: "set", ws: WS, urls: ["https://1.x", "https://2.x", "https://3.x", "https://4.x", "https://5.x"] },
  ]);
  const kept = { [WS]: { relays: [{ url: "https://kept.example", by: "x" }], off: ["direct"], at: 500, station: B } };
  await sameWays("a record kept before, a peer's newer and older, answered as a peer asks", stateOf(A, { ways: { relays: ["https://said.example"], off: ["lan"] } }), [
    { do: "take", ws: WS, record: { relays: [], off: [], at: 500, station: A } },
    { do: "take", ws: WS, record: { relays: [], off: [], at: 500, station: "0" } },
    { do: "take", ws: WS, record: { relays: ["https://n.example"], off: [], at: 499, station: "z" } },
    { do: "answer", ws: WS, request: { method: "ways.get" } },
    { do: "answer", ws: "w9", request: { method: "ways.get" } },
    { do: "answer", ws: WS, request: { method: "ways.put", record: { relays: 1 } } },
    { do: "answer", ws: WS, request: { method: "ways.put", record: { relays: [], off: ["lan"], at: 900, station: B } } },
    { do: "answer", ws: WS, request: { method: "ways.nope" } },
    { now: 100, do: "add", ws: WS, url: "https://own.example" },
  ], kept);
  await sameWays("what the plane kept before the stations did, and its relays told apart or not", stateOf(A, { stillfail_relays: undefined, ways: { relays: ["https://theirs.example/", "ftp://bad"], off: ["tailnet"] } }), [
    { now: 1, do: "add", ws: WS, url: "https://theirs.example" },
    { now: 2, do: "add", ws: WS, url: "https://r2.still.fail" },
    { now: 3, do: "setWay", ws: WS, way: "https://theirs.example", on: false },
  ]);
  await sameWays("two workspaces, a peer in both and one in one: dialed through both's, held to what both turn off", stateOf(A, {
    peers: [{ id: B }, { id: C }],
    joined: [{ workspace: W2, workspace_name: "W2", name: "there", peers: [{ id: B }], revocations: [] }, { workspace: "w3", peers: [{ id: C }], revocations: [], locked: true }],
  }), [
    { now: 1, do: "add", ws: WS, url: "https://one.example" },
    { now: 2, do: "add", ws: W2, url: "https://two.example" },
    { now: 3, do: "setWay", ws: WS, way: "ours", on: false },
    { now: 4, do: "setWay", ws: W2, way: "https://r1.still.fail", on: false },
    { now: 5, do: "setWay", ws: W2, way: "ours", on: false },
    { now: 6, do: "state", state: stateOf(A, { peers: [{ id: C }] }) },
  ]);
  await sameWays("a rig of the workspace is dialed as its stations are", stateOf(A, { peers: [], rigs: [{ id: C, owner: "u", name: "r" }] }), [
    { now: 1, do: "add", ws: WS, url: "https://one.example" },
    { now: 2, do: "setWay", ws: WS, way: "ours", on: false },
  ]);
  await sameWays("no workspace at all: still.fail's relays as they are", { ...stateOf(A), removed_at: 5, removed_code: 4004 }, [
    { now: 1, do: "add", ws: WS, url: "https://one.example" },
  ]);
});

async function sameMarks(name: string, state: any, steps: any[], kept?: object) {
  const text = kept === undefined ? undefined : JSON.stringify(kept);
  const { cloud, state: read } = cloudOf(state, { marks: text });
  const marks = new StationMarks(cloud, join(cloud.data, "mesh", "station-marks.json"));
  const told: string[] = [];
  const stop = marks.listen((s) => told.push(s));
  const steps2: unknown[] = [];
  for (const step of steps) {
    if (typeof step.now === "number") mock.method(wall, "now", () => step.now);
    steps2.push(outcome(() => {
      switch (step.do) {
        case "change": {
          const said: any = {};
          for (const k of ["name", "emoji", "icon"]) if (k in step) said[k] = step[k];
          return marks.change(said, { name: step.was?.name ?? "", emoji: step.was?.emoji ?? "", icon: step.was?.icon ?? "" });
        }
        case "take": { const r = markOf(step.record); return r === null ? null : marks.take(step.station, r); }
        case "answer": return answerMarks(marks, step.request, step.ws);
      }
      throw new Error(`no such step: ${step.do}`);
    }));
  }
  stop();
  await marks.written();
  const of: Record<string, unknown> = {};
  for (const m of cloud.memberships()) of[m.workspace] = { stations: marks.stationsOf(m.workspace), of: marks.of(m.workspace) };
  let file: unknown = null;
  try { file = JSON.parse(readFileSync(join(cloud.data, "mesh", "station-marks.json"), "utf8")); } catch {}
  const ts = plain({ steps: steps2, told, of, file });
  const ours = await mb({ op: "marks", state: read, kept: text ?? null, now: 0, steps });
  assert.deepEqual(ours, ts, name);
  mock.restoreAll();
}

test("the marks: changed only here and only well, the newer of a peer's kept, answered for its workspace's stations", { skip }, async () => {
  await sameMarks("changes and refusals", stateOf(A, { peers: [{ id: B }, { id: "not-hex" }, { id: B }] }), [
    { now: 100, do: "change", name: "  the   station ", was: { name: "cloud's", emoji: "", icon: "" } },
    { now: 50, do: "change", emoji: "🚀 extra" },
    { now: 60, do: "change", icon: "glyph:rocket:blue" },
    { now: 70, do: "change", name: "" },
    { now: 70, do: "change", emoji: "x" },
    { now: 70, do: "change", icon: "data:x" },
    { now: 80, do: "change", emoji: null, icon: "" },
    { do: "take", station: B, record: { name: "peer", at: 5 } },
    { do: "take", station: B, record: { name: "older", at: 5 } },
    { do: "take", station: B, record: { name: "newer", emoji: "🇨🇳", at: 6 } },
    { do: "answer", ws: WS, request: { method: "stationMarks.get" } },
    { do: "answer", ws: WS, request: { method: "stationMarks.put", marks: { [B]: { name: "put", at: 9 }, [C]: { name: "not of it", at: 9 } } } },
    { do: "answer", ws: WS, request: { method: "stationMarks.put", marks: { [B]: { name: "", at: 10 } } } },
    { do: "answer", ws: WS, request: { method: "stationMarks.nope" } },
  ]);
  await sameMarks("one not enrolled refuses its own change", { ...stateOf(""), station: "" }, [{ now: 5, do: "change", name: "x" }]);
  const kept = { [A]: { name: "mine", emoji: "", icon: "", at: 3 }, [C]: { name: "c", emoji: "", icon: "", at: 4 }, nothex: { name: "x", at: 1 }, [B]: { name: "", at: 1 } };
  await sameMarks("what was kept, read back", stateOf(A, { peers: [{ id: B }, { id: C }] }), [{ now: 2, do: "change", emoji: "👍🏽" }], kept);
});

// ── a dial on one clock ──

/// Timers the case's own: what is due fires in the order it was set.
class FakeTime {
  now = 0;
  seq = 0;
  waits: { at: number; seq: number; f: () => void }[] = [];
  after = (ms: number, f: () => void) => {
    const w = { at: this.now + ms, seq: ++this.seq, f };
    this.waits.push(w);
    return () => void (this.waits = this.waits.filter((x) => x !== w));
  };
  /// The clock moved to `to`, each due fired at its time; `settle` between them (what a fired one set going).
  async advance(to: number, settle: () => Promise<void> = async () => {}) {
    for (;;) {
      const due = this.waits.filter((w) => w.at <= to).sort((a, b) => a.at - b.at || a.seq - b.seq)[0];
      if (due === undefined) break;
      this.waits = this.waits.filter((w) => w !== due);
      if (due.at > this.now) this.now = due.at;
      due.f();
      await settle();
    }
    if (to > this.now) this.now = to;
  }
}

class Sock extends EventEmitter {
  readonly i: number;
  readonly trace: unknown[];
  readonly time: FakeTime;
  constructor(i: number, trace: unknown[], time: FakeTime) {
    super();
    this.i = i;
    this.trace = trace;
    this.time = time;
  }
  destroy() { this.trace.push({ t: this.time.now, destroy: this.i }); }
}

async function sameDial(name: string, c: { entry: unknown; budget: number; throws?: string[]; script: any[]; until: number }) {
  const time = new FakeTime();
  const trace: unknown[] = [];
  const socks: Sock[] = [];
  const io: DialIO = {
    after: time.after,
    tls: (host, port, servername) => {
      const i = socks.length;
      trace.push({ t: time.now, dial: i, host, port, servername });
      const s = new Sock(i, trace, time);
      socks.push(s);
      if ((c.throws?.[i] ?? "") !== "") throw new Error(c.throws![i]);
      return s as any;
    },
  };
  const entry = c.entry === null ? null : cloudEntry({ cloudEntry: c.entry });
  const cancel = dialCloud(io, CLOUD_ORIGIN, entry, c.budget, (error, socket) => {
    if (error === null) trace.push({ t: time.now, won: (socket as unknown as Sock).i });
    else trace.push({ t: time.now, error: error.message, errors: error instanceof AggregateError ? error.errors.map((e) => (e as Error).message) : [] });
  });
  for (const step of c.script) {
    await time.advance(step.at);
    if (step.cancel === true) { cancel(); continue; }
    const s = socks[step.i];
    if (s === undefined) { trace.push({ t: time.now, missing: step.i }); continue; }
    if (step.ev === "secure") s.emit("secureConnect");
    else if (step.ev === "error") s.emit("error", new Error(step.msg ?? ""));
  }
  await time.advance(c.until);
  const ts = plain({ trace, waiting: time.waits.length });
  assert.deepEqual(await mb({ op: "dial", ...c }), ts, name);
}

test("a dial's candidates: direct first, the entry a second later, one budget, a cancel owning only what is pending", { skip }, async () => {
  const entry = { origin: CLOUD_ORIGIN, host: "entry.test", port: 24443 };
  await sameDial("direct fast", { entry, budget: 10_000, script: [{ at: 10, i: 0, ev: "secure" }], until: 30_000 });
  await sameDial("no entry, direct fails", { entry: null, budget: 10_000, script: [{ at: 5, i: 0, ev: "error", msg: "refused" }], until: 30_000 });
  await sameDial("no entry, nothing answers", { entry: null, budget: 10_000, script: [], until: 30_000 });
  await sameDial("entry wins after the hedge, late direct let go", { entry, budget: 10_000, script: [{ at: 1500, i: 1, ev: "secure" }, { at: 1600, i: 0, ev: "secure" }, { at: 1700, i: 0, ev: "error", msg: "late" }], until: 30_000 });
  await sameDial("direct fails early: entry at once, it fails too", { entry, budget: 10_000, script: [{ at: 100, i: 0, ev: "error", msg: "direct refused" }, { at: 200, i: 1, ev: "error", msg: "entry reset" }], until: 30_000 });
  await sameDial("both silent: the presence budget", { entry, budget: 20_000, script: [], until: 60_000 });
  await sameDial("cancelled while both are pending, a success after it let go", { entry, budget: 20_000, script: [{ at: 1200, cancel: true }, { at: 1300, i: 1, ev: "secure" }, { at: 1400, cancel: true }], until: 60_000 });
  await sameDial("the TLS throws for the direct one: the entry at once", { entry, budget: 10_000, throws: ["no route"], script: [{ at: 50, i: 1, ev: "secure" }], until: 30_000 });
  await sameDial("the direct fails after the entry started: the entry still has the budget", { entry, budget: 10_000, script: [{ at: 1000, i: 0, ev: "error", msg: "slow" }, { at: 9999, i: 1, ev: "secure" }], until: 30_000 });
});

// ── two stations brought level ──

type Peer = { state: any; kept?: string; delay?: number; down?: [number, number][]; before?: boolean; home?: string };

async function sameFollow(name: string, kind: "ways" | "marks", c: { state: any; kept?: string; peersCurrent?: boolean; peers: Record<string, Peer>; events: any[]; until: number }) {
  const time = new FakeTime();
  mock.method(wall, "now", () => time.now);
  const kept = c.kept === undefined ? {} : kind === "ways" ? { ways: c.kept } : { marks: c.kept };
  const me = cloudOf(c.state, kept);
  if (c.peersCurrent !== undefined) me.cloud.peersCurrent = c.peersCurrent;
  const ways = waysOf(me.cloud);
  const marks = new StationMarks(me.cloud, join(me.cloud.data, "mesh", "station-marks.json"));
  const peers = new Map<string, { cfg: Peer; cloud: Cloud; ways: Ways; marks: StationMarks }>();
  for (const [id, cfg] of Object.entries(c.peers)) {
    const p = cloudOf(cfg.state, cfg.kept === undefined ? {} : kind === "ways" ? { ways: cfg.kept } : { marks: cfg.kept });
    peers.set(id, { cfg, cloud: p.cloud, ways: waysOf(p.cloud), marks: new StationMarks(p.cloud, join(p.cloud.data, "mesh", "station-marks.json")) });
  }
  const trace: unknown[] = [];
  const call = (peer: string, ws: string | null, request: unknown) => new Promise<unknown>((resolve, reject) => {
    const p = peers.get(peer)!;
    const at = time.now;
    trace.push({ t: at, peer, ws, request });
    time.after(p.cfg.delay ?? 0, () => {
      const down = (p.cfg.down ?? []).some(([from, to]) => from <= at && at < to);
      let answer: { ok: unknown } | { error: string };
      if (p.cfg.before === true) answer = { error: "unknown method" };
      else if (down) answer = { error: "the peer is offline" };
      else {
        const askedIn = ws ?? p.cfg.home ?? "";
        answer = outcome(() => (kind === "ways" ? answerWays(p.ways, request, askedIn) : answerMarks(p.marks, request, askedIn))) as any;
      }
      trace.push({ t: time.now, peer, answer: "ok" in answer ? answer.ok : { error: answer.error } });
      if ("ok" in answer) resolve(answer.ok);
      else reject(new Error(answer.error));
    });
  });
  const settle = async () => { for (let i = 0; i < 20; i++) await new Promise((r) => setImmediate(r)); };
  const stop = kind === "ways" ? followWays(ways, call as any, time.after) : followMarks(marks, call as any, time.after);
  await settle();
  for (const ev of c.events) {
    await time.advance(ev.at, settle);
    try {
      if (ev.do === "add") addRelay(ways, ev.ws, ev.url, null);
      else if (ev.do === "mark") marks.change({ name: ev.name }, { name: "", emoji: "", icon: "" });
      else if (ev.do === "roster") {
        if (typeof ev.peersCurrent === "boolean") me.cloud.peersCurrent = ev.peersCurrent;
        me.cloud.update((st) => { if (ev.state !== undefined) { for (const k of Object.keys(st)) delete (st as any)[k]; Object.assign(st, ev.state); } });
      } else if (ev.do === "stop") stop();
    } catch {}
    await settle();
  }
  await time.advance(c.until, settle);
  stop();
  const summary = (cloud: Cloud, w: Ways, m: StationMarks) => {
    const out: Record<string, unknown> = {};
    for (const ms of cloud.memberships()) out[ms.workspace] = kind === "ways" ? w.record(ms.workspace) : { stations: m.stationsOf(ms.workspace), of: m.of(ms.workspace) };
    return out;
  };
  const peersNow: Record<string, unknown> = {};
  for (const [id, p] of peers) peersNow[id] = summary(p.cloud, p.ways, p.marks);
  const ts = plain({ trace, mine: summary(me.cloud, ways, marks), peers: peersNow, waiting: time.waits.length });
  const ours = await mb({ op: "follow", follow: kind, ...c, state: me.state, peers: Object.fromEntries([...peers].map(([id, p]) => [id, { ...p.cfg, state: plain(p.cloud.state) }])) });
  assert.deepEqual(ours, ts, name);
  mock.restoreAll();
}

test("through the shell's own entry: a dial raced, HTTP and a WebSocket over the route that won, Host the origin's", { skip }, async () => {
  // The origin's direct candidate (cloud.invalid, a name that resolves nowhere: RFC 6761) fails, the entry (this
  // server) wins; the request and the socket go to it by the shell's `"entry"`, their Host and URL still the origin's.
  // (A name, as still.fail's origin is: reqwest resolves no IP address's URL, so the shell's entry takes names alone.)
  const heard: string[] = [];
  const server = createServer((req, res) => {
    heard.push(`${req.method} ${req.url} ${req.headers.host}`);
    res.end(req.url === "/v1/me" ? "me" : "ok");
  });
  const sockets = new WebSocketServer({ server });
  sockets.on("connection", (ws, req) => {
    heard.push(`upgrade ${req.url} ${req.headers.host} ${req.headers["x-stillfail-station"]}`);
    ws.on("message", (m) => ws.send(`echo:${m}`));
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  try {
    const port = (server.address() as AddressInfo).port;
    const ours = await mb({
      op: "hostEntry",
      origin: "http://cloud.invalid",
      entry: { host: "127.0.0.1", port },
      budget: 10_000,
      path: "/v1/me",
      ws: "ws://cloud.invalid/v1/presence",
      headers: [["x-stillfail-station", "s1"]],
      send: "hi",
    });
    assert.deepEqual(ours, {
      won: { host: "127.0.0.1", port },
      http: { status: 200, body: "me" },
      ws: [{ open: true }, { message: "echo:hi" }],
    });
    assert.deepEqual(heard, [
      "GET /healthz cloud.invalid",
      "GET /v1/me cloud.invalid",
      "upgrade /v1/presence cloud.invalid s1",
    ]);
  } finally {
    sockets.close();
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
  }
});

test("ways brought level: through a peer down, retried sooner at first, one from before left be, rigs too", { skip }, async () => {
  const mine = JSON.stringify({ [WS]: { relays: [{ url: "https://own.example" }], off: [], at: 50, station: A } });
  const theirs = JSON.stringify({ [WS]: { relays: [], off: ["lan"], at: 70, station: B } });
  await sameFollow("mine to a peer down a while", "ways", { state: stateOf(A), kept: mine, peers: { [B]: { state: stateOf(B), delay: 10, down: [[0, 40_000]], home: WS } }, events: [], until: 200_000 });
  await sameFollow("theirs newer, taken", "ways", { state: stateOf(A), kept: mine, peers: { [B]: { state: stateOf(B), kept: theirs, delay: 3, home: WS } }, events: [{ at: 500, do: "add", ws: WS, url: "https://later.example" }], until: 10_000 });
  await sameFollow("a station from before", "ways", { state: stateOf(A), peers: { [B]: { state: stateOf(B), delay: 5, before: true, home: WS } }, events: [{ at: 1000, do: "add", ws: WS, url: "https://own.example" }, { at: 2000, do: "add", ws: WS, url: "https://two.example" }], until: 100_000 });
  await sameFollow("two peers and a rig, one joined workspace asked by its id", "ways", {
    state: stateOf(A, { peers: [{ id: B }, { id: C }], rigs: [{ id: "d".repeat(64), owner: "u" }], joined: [{ workspace: W2, peers: [{ id: B }], revocations: [] }] }),
    kept: JSON.stringify({ [WS]: { relays: [], off: ["tailnet"], at: 9, station: A }, [W2]: { relays: [], off: ["direct"], at: 9, station: A } }),
    peers: {
      [B]: { state: stateOf(B, { joined: [{ workspace: W2, peers: [{ id: A }], revocations: [] }] }), delay: 7, down: [[0, 6000]], home: WS },
      [C]: { state: stateOf(C), delay: 1, home: WS },
      ["d".repeat(64)]: { state: stateOf("d".repeat(64)), delay: 2, home: WS },
    },
    events: [{ at: 3000, do: "add", ws: W2, url: "https://two.example" }],
    until: 120_000,
  });
  await sameFollow("no roster current until it comes, then a peer gone from it", "ways", {
    state: stateOf(A), kept: mine, peersCurrent: false, peers: { [B]: { state: stateOf(B), delay: 4, down: [[0, 100_000]], home: WS } },
    events: [{ at: 100, do: "roster", peersCurrent: true }, { at: 7000, do: "roster", state: stateOf(A, { peers: [] }) }], until: 400_000,
  });
});

test("marks brought level: the newer of each kept by both, retried through a peer down, a rig asking none", { skip }, async () => {
  const mine = JSON.stringify({ [A]: { name: "mine", emoji: "", icon: "", at: 10 } });
  const theirs = JSON.stringify({ [A]: { name: "older", emoji: "", icon: "", at: 5 }, [B]: { name: "peer", emoji: "🚀", icon: "", at: 7 }, [C]: { name: "not of it", emoji: "", icon: "", at: 9 } });
  await sameFollow("both ways", "marks", { state: stateOf(A), kept: mine, peers: { [B]: { state: stateOf(B), kept: theirs, delay: 2, home: WS } }, events: [{ at: 50, do: "mark", name: "renamed" }], until: 1000 });
  await sameFollow("a peer down, doubling to the cap", "marks", { state: stateOf(A), peers: { [B]: { state: stateOf(B), delay: 0, down: [[0, 3_000_000]], home: WS } }, events: [{ at: 1, do: "mark", name: "here" }], until: 4_000_000 });
  await sameFollow("a rig keeps none", "marks", { state: stateOf(A, { rig: { owner: "u", owner_email: "", owner_name: "", person: "e".repeat(64) } }), peers: { [B]: { state: stateOf(B), home: WS } }, events: [{ at: 5, do: "mark", name: "x" }], until: 1000 });
  await sameFollow("one from before", "marks", { state: stateOf(A), kept: mine, peers: { [B]: { state: stateOf(B), before: true, delay: 1, home: WS } }, events: [{ at: 50, do: "mark", name: "again" }], until: 1000 });
});

test("registered mesh ways remain off when the URL relay list is replaced", { skip }, async () => {
  const state = stateOf(A, { mesh_relays: [{ node: B, name: "global", generation: 1, revision: 1, address: { id: B, addrs: [] } }] });
  const result = await sameWays("mesh way registration and preservation", state, [
    { now: 10, do: "setWay", ws: WS, way: `mesh:${B}`, on: false },
    { now: 20, do: "set", ws: WS, urls: [] },
    { now: 30, do: "setWay", ws: WS, way: `mesh:${C}`, on: false },
  ]);
  assert.deepEqual((result.steps[1] as any).ok.off, [`mesh:${B}`]);
  assert.deepEqual(result.steps[2], { error: "no such way: a registered relay, or ours, lan, tailnet, direct" });
});

// ── the plane's frames ──

async function sameFrames(name: string, state: any, frames: any[]) {
  const { cloud, state: read } = cloudOf(state);
  const out: unknown[] = [];
  for (const f of frames) {
    if (typeof f.now === "number") mock.method(wall, "now", () => f.now * 1000);
    const sent: unknown[] = [];
    const apply = () => applyState(cloud, f.text ?? JSON.stringify(f.frame), (frame) => sent.push(frame));
    if (f.reject) assert.throws(apply);
    else apply();
    let file: unknown = null;
    try { file = JSON.parse(readFileSync(join(cloud.data, "mesh", "cloud.json"), "utf8")); } catch {}
    out.push(plain({ state: file, sent, peersCurrent: cloud.peersCurrent, reached: cloud.reached, rostersSaid: cloud.rostersSaid, planeLockSeq: cloud.planeLockSeq, memberships: cloud.memberships().map((m) => m.workspace) }));
  }
  const ours = (await mb({ op: "frames", state: read, now: frames[0]?.now ?? 0, frames })).map((o: any) => { delete o.grantsGone; return o; });
  assert.deepEqual(ours, out, name);
  mock.restoreAll();
  return out;
}

test("the plane's frames make the same cloud.json; whole ↔ rig only as both agree, within the hour", { skip }, async () => {
  const self = { owner: "u1", owner_email: "u1@x", owner_name: "U1", person: "c".repeat(64) };
  await sameFrames("where it is, what it is called, its relays, roster and rigs", stateOf(A), [
    { now: 1000, frame: { type: "state", workspace: WS, workspace_name: "Renamed", name: "new name", origin: "https://app.still.fail", relay_url: "https://r9.example", relay_urls: ["https://r9.example", 3], stillfail_relays: ["https://r9.example"], peers: [{ id: B, name: "b" }], gateway_keys: ["g1", 2], grant_keys: { k: 1 }, revocations: [{ kind: "d", id: "1", at: 1 }], rigs: [{ id: C, owner: "u" }, { id: "x", owner: "u" }], ways: { relays: ["https://w.example"], off: ["lan"] } } },
    { now: 1001, frame: { type: "state", peers: "none", grant_keys: [1], revocations: [{ kind: "d" }] } },
    { now: 1002, frame: { type: "state", workspaces: [{ workspace: W2, workspace_name: "W2", peers: [{ id: C }], revocations: [] }, { workspace: "w3", locked: true }], lock: null } },
    { now: 1003, frame: { type: "state", peers: [], workspaces: [], lock: { seq: 3, hash: "h" } } },
    { now: 1004, text: "not json" },
    { now: 1005, frame: { type: "revoke", kind: "device", id: "d1", at: 5 } },
    { now: 1006, frame: { type: "revoke", kind: "device", id: "d1", at: 6, workspace: "w9" } },
    { now: 1007, frame: { type: "revoke", kind: "device", id: "d1", at: -1 } },
    { now: 1008, frame: { type: "other" } },
    { now: 1009, frame: { type: "state", workspace: "w-moved", peers: [] } },
  ]);
  await sameFrames("whole to tasks: asked here and listed so by the plane as that person's", stateOf(A, { rig_pending: { ...self, at: 5000 } }), [
    { now: 5010, frame: { type: "state", peers: [], rig: null } },
    { now: 5020, frame: { type: "state", peers: [], rig: { owner: "u2" } } },
    { now: 5030, frame: { type: "state", peers: [], rig: { owner: "u1" }, workspaces: [{ workspace: W2 }] } },
    { now: 5040, frame: { type: "state", peers: [], rig: { owner: "u1" } } },
  ]);
  await sameFrames("whole to tasks: the hour over, forgotten", stateOf(A, { rig_pending: { ...self, at: 5000 } }), [
    { now: 8600, frame: { type: "state", peers: [], rig: { owner: "u1" } } },
    { now: 8601, frame: { type: "state", peers: [], rig: { owner: "u1" } } },
  ]);
  await sameFrames("tasks to whole: its person signed, the plane lists it whole", stateOf(A, { rig: self, full_pending: { at: 100 }, rigs: [{ id: C, owner: "u" }] }), [
    { now: 200, frame: { type: "state", peers: [], rig: { owner: "u1" }, rigs: [{ id: C, owner: "u" }] } },
    { now: 300, frame: { type: "state", peers: [], rig: null, rigs: [{ id: C, owner: "u" }] } },
  ]);
  await sameFrames("tasks to whole: the hour over, stays a rig", stateOf(A, { rig: self, full_pending: { at: 100 } }), [
    { now: 3701, frame: { type: "state", peers: [], rig: null } },
  ]);
  await sameFrames("the plane alone changes nothing of what the machine is", stateOf(A), [
    { now: 10, frame: { type: "state", peers: [], rig: { owner: "u1" } } },
  ]);
  await sameFrames("a joined workspace takes over a home it was taken out of", stateOf(A, { joined: [{ workspace: W2, workspace_name: "W2", name: "there", peers: [], revocations: [] }] }), [
    { now: 10, frame: { type: "state", workspace: W2, workspace_name: "W2", peers: [{ id: B }], workspaces: [] } },
  ]);
});

test("global mesh frames normalize metadata and reject malformed registries before any state changes", { skip }, async () => {
  const row = { node: B, name: "🚀".repeat(40), generation: 1, revision: 2, address: { id: B, addrs: [{ Relay: "HTTPS://RELAY.EXAMPLE:443/path" }, { Ip: "[fe80::1%eth0]:1234" }, { Ip: "127.0.0.1:00123" }] } };
  const invalid = [
    null, {}, Array(33).fill(row), [row, row],
    [{ ...row, generation: 0 }], [{ ...row, revision: 1.5 }], [{ ...row, revision: 2 ** 53 }],
    [{ ...row, name: "🚀".repeat(41) }], [{ ...row, node: B.toUpperCase() }],
    [{ ...row, address: { id: C, addrs: [] } }],
    ...[
      [{ Ip: "01.2.3.4:1234" }], [{ Ip: "[::1]:65536" }], [{ Ip: "[fe80::1%bad_zone]:1" }],
      [{ Relay: "https://user:pass@relay.example" }], [{ Relay: "https://relay.example/?query" }],
      [{ Custom: "recursive" }], [{ Ip: "127.0.0.1:1", Relay: "https://relay.example" }],
      Array(9).fill({ Ip: "127.0.0.1:1" }),
    ].map(addrs => [{ ...row, address: { id: B, addrs } }]),
  ];
  const frames = [
    { now: 1, frame: { type: "state", peers: [], mesh_relays: [row] } },
    ...invalid.map(mesh_relays => ({ reject: true, now: 2, frame: { type: "state", workspace: "must-not-move", name: "must-not-change", peers: [{ id: C }], mesh_relays } })),
    { now: 3, frame: { type: "state", peers: [] } },
  ];
  const result = await sameFrames("global mesh metadata and atomic rejection", stateOf(A), frames);
  assert.deepEqual((result[0] as any).state.mesh_relays, [{ ...row, address: { id: B, addrs: [{ Relay: "https://relay.example/path" }, ...row.address.addrs.slice(1)] } }]);
  for (const rejected of result.slice(1, -1)) assert.deepEqual(rejected, result[0]);
  assert.deepEqual((result.at(-1) as any).state.mesh_relays, []);
  const reloaded = await sameFrames("persisted global mesh metadata survives reload",
    (result[0] as any).state, [{ now: 4, frame: { type: "other" } }]);
  assert.deepEqual((reloaded[0] as any).state.mesh_relays, (result[0] as any).state.mesh_relays);
});

test("another station on this key: three replaced in a row before they held, ended only by one that holds", { skip }, async () => {
  const events = [
    { code: 4000, held: false }, { code: 4000, held: false }, { code: null, held: false }, { code: 4000, held: false }, { steady: true },
    { code: 4000, held: true }, { code: 4000, held: false }, { code: 4000, held: false }, { code: 4000, held: false }, { code: 4000, held: false },
    { code: 1001, held: false }, { steady: true }, { code: 4000, held: false },
  ];
  const told: boolean[] = [];
  const r = new Replaced((b) => told.push(b));
  const after: unknown[] = [];
  for (const e of events) {
    if ("steady" in e) r.steady();
    else r.ended(e.code, e.held);
    after.push({ inARow: r.inARow, conflict: r.conflict });
  }
  assert.deepEqual(await mb({ op: "replaced", events }), { after, told });
});

test("the ways told still.fail's plane on a socket: each record once, none while closed, none by a rig", { skip }, async () => {
  for (const state of [stateOf(A, { joined: [{ workspace: W2, peers: [], revocations: [] }] }), stateOf(A, { rig: { owner: "u", owner_email: "", owner_name: "", person: "e".repeat(64) } })]) {
    const { cloud, state: read } = cloudOf(state);
    const ways = waysOf(cloud);
    let open = true;
    const sent: unknown[] = [];
    const tell = waysTeller(cloud, ways, (f) => sent.push(f), () => open);
    const steps = [
      {}, { ws: WS, take: { relays: ["https://a.example"], off: ["lan"], at: 5, station: B } }, {}, { open: false, ws: W2, take: { relays: [], off: [], at: 6, station: B } },
      { open: true }, { ws: WS, take: { relays: [{ url: "https://b.example", by: "x" }], off: [], at: 7, station: A } },
    ];
    const out: unknown[] = [];
    for (const step of steps as any[]) {
      if (typeof step.open === "boolean") open = step.open;
      if (step.take !== undefined) ways.take(step.ws, recordOf(step.take)!);
      tell();
      out.push(plain(sent.splice(0)));
    }
    await ways.written();
    assert.deepEqual(await mb({ op: "waysTeller", state: read, steps }), out);
  }
});
