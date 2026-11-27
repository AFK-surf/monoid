// Real TS vs Pion differential parity test suite (Layer 1 + Layer 2).
// Directly imports `client/core-ts/src/*.ts` as the single source of truth and drives the
// compiled native `pion/client-core/packages/parity_cli` binary over JSONL stdin/stdout RPC.
// Zero hardcoded expected values; asserts 0 diffs across fixed vectors + seeded random fuzz.

import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { after, before, test } from "node:test";
import { fileURLToPath } from "node:url";

import * as deltaTs from "../../../client/core-ts/src/delta.ts";
import * as collectionsTs from "../../../client/core-ts/src/collections.ts";
import * as protocolTs from "../../../client/core-ts/src/protocol.ts";
import * as digestTs from "../../../client/core-ts/src/digest.ts";
import * as presetRecordsTs from "../../../client/core-ts/src/preset-records.ts";
import * as presetsKeptTs from "../../../client/core-ts/src/presets-kept.ts";
import * as boardDraftsTs from "../../../client/core-ts/src/board-drafts.ts";
import * as lockTs from "../../../client/core-ts/src/lock.ts";
import * as vaultCryptoTs from "../../../client/core-ts/src/vault/crypto.ts";
import { ed25519 } from "../../../client/core-ts/node_modules/@noble/curves/ed25519.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, "../../..");
const clientCoreDir = path.resolve(__dirname, "..");
const pioncBin = process.env.PIONC || path.join(os.homedir(), ".pion/bin/pionc");

// Deterministic PRNG (Mulberry32)
function makeRng(seed) {
  let a = seed >>> 0;
  return {
    next() {
      a = (a + 0x6d2b79f5) >>> 0;
      let t = Math.imul(a ^ (a >>> 15), 1 | a);
      t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    },
    int(lo, hi) {
      return lo + Math.floor(this.next() * (hi - lo + 1));
    },
    pick(arr) {
      return arr[this.int(0, arr.length - 1)];
    },
    bytes(len) {
      const out = new Uint8Array(len);
      for (let i = 0; i < len; i++) out[i] = this.int(0, 255);
      return out;
    },
  };
}

const toHex = (u8) => Buffer.from(u8).toString("hex");
const fromHex = (h) => new Uint8Array(Buffer.from(h, "hex"));

// Persistent native parity_cli JSONL RPC client
class ParityClient {
  constructor(binPath) {
    this.proc = spawn(binPath, [], { stdio: ["pipe", "pipe", "pipe"] });
    this.buf = "";
    this.queue = [];
    this.stderr = "";
    this.proc.stderr.on("data", (d) => {
      this.stderr += d.toString("utf8");
    });
    this.proc.stdout.on("data", (chunk) => {
      this.buf += chunk.toString("utf8");
      let nl;
      while ((nl = this.buf.indexOf("\n")) >= 0) {
        const line = this.buf.slice(0, nl);
        this.buf = this.buf.slice(nl + 1);
        const waiter = this.queue.shift();
        if (waiter) {
          try {
            waiter.resolve(JSON.parse(line));
          } catch (e) {
            waiter.reject(new Error(`Bad JSON from parity_cli: ${line}\n${e}`));
          }
        }
      }
    });
    this.proc.on("exit", (code) => {
      while (this.queue.length > 0) {
        this.queue.shift().reject(new Error(`parity_cli exited with code ${code}: ${this.stderr}`));
      }
    });
  }

  callRaw(op, args) {
    return new Promise((resolve, reject) => {
      this.queue.push({ resolve, reject });
      this.proc.stdin.write(`${JSON.stringify({ op, args })}\n`);
    });
  }

  async call(op, args) {
    const resp = await this.callRaw(op, args);
    if ("err" in resp) throw new Error(`parity_cli error on ${op}: ${resp.err}`);
    return resp.ok;
  }

  close() {
    this.proc.stdin.end();
    this.proc.kill();
  }
}

let rpc;
let builtBin = null;
const counts = {
  moduleA: 0,
  moduleB: 0,
  moduleC: 0,
  moduleD: 0,
  moduleE: 0,
};

before(() => {
  builtBin = path.join(os.tmpdir(), `pion-client-core-parity-cli-${process.pid}`);
  execFileSync(pioncBin, ["build", "-o", builtBin, "pion/client-core/packages/parity_cli"], {
    cwd: repoRoot,
    stdio: "pipe",
  });
  assert.ok(fs.existsSync(builtBin), "parity_cli binary not found after pionc build");
  rpc = new ParityClient(builtBin);
});

after(() => {
  if (rpc) rpc.close();
  if (builtBin && fs.existsSync(builtBin)) {
    try { fs.unlinkSync(builtBin); } catch {}
  }
  console.log("Parity test call counts (0 diffs):", counts);
});

// ---------------------------------------------------------------------------
// Module A: delta.ts vs packages/protocol/src/delta.pion
// ---------------------------------------------------------------------------
test("Module A: delta.ts (diff, apply, jsonLength, largerThan) — vectors + 300 seeded fuzz", async () => {
  const fixedPairs = [
    [{ a: [1, { b: null }] }, { a: [1, { b: null }] }],
    [{ detail: { timeline: [1, 2], usage: { n: 1 } } }, { detail: { timeline: [1, 2, 3, 4], usage: { n: 1 } } }],
    [{ items: [{ text: "a" }, { text: "b" }] }, { items: [{ text: "a" }, { text: "bc" }] }],
    [{ state: "offline", message: "断了" }, { state: "online", since: 5 }],
    [{ a: [1, 2, 3] }, { a: [1, 2] }],
    [{ a: [1, 2] }, { a: [0, 1, 2] }],
    [{ a: { b: 1 } }, { a: [1] }],
    [[1], "x"],
    [{ z: 1, a: 2, "😀": 3, "中文": 4 }, { "中文": 5, "😀": 3, b: 9, a: 2 }],
    [{ state: "offline" }, { state: "online" }],
    [
      { timeline: Array.from({ length: 100 }, (_, i) => `message ${i}`) },
      { timeline: [...Array.from({ length: 100 }, (_, i) => `message ${i}`), "one more"] },
    ],
  ];

  for (const [oldV, nextV] of fixedPairs) {
    const tsOps = deltaTs.diff(oldV, nextV);
    const piOps = await rpc.call("delta.diff", { old: oldV, next: nextV });
    assert.deepEqual(piOps, tsOps, `diff mismatch on ${JSON.stringify(oldV)} -> ${JSON.stringify(nextV)}`);

    const tsApplied = deltaTs.apply(structuredClone(oldV), tsOps);
    const piApplied = await rpc.call("delta.apply", { value: oldV, ops: tsOps });
    assert.deepEqual(piApplied, tsApplied, "apply mismatch");

    const tsLarger = deltaTs.largerThan(tsOps, nextV);
    const piLarger = await rpc.call("delta.largerThan", { ops: tsOps, value: nextV });
    assert.equal(piLarger, tsLarger, "largerThan mismatch");

    const tsLen = deltaTs.jsonLength(nextV);
    const piLen = await rpc.call("delta.jsonLength", { value: nextV });
    assert.equal(piLen, tsLen, "jsonLength mismatch");
    counts.moduleA += 4;
  }

  // Invalid-path apply edge cases
  const invalidApplyCases = [
    [{ a: 1 }, [{ path: ["a", "b"], set: 2 }]],
    [{ a: 1 }, [{ path: ["missing"], append: [1] }]],
    [{ a: [1, 2] }, [{ path: ["a", 5], set: 9 }]],
    [{ a: 1 }, [{ path: [], remove: true }]],
    [[1, 2], [{ path: [0], remove: true }]],
    [{ a: 1 }, [{ path: ["b"], remove: true }]],
  ];
  for (const [val, ops] of invalidApplyCases) {
    const tsOut = deltaTs.apply(structuredClone(val), ops);
    const piOut = await rpc.call("delta.apply", { value: val, ops });
    assert.deepEqual(piOut, tsOut, `invalid-path apply mismatch: ${JSON.stringify({ val, ops })}`);
    counts.moduleA++;
  }

  // 300 seeded random JSON trees
  const rng = makeRng(20261123);
  const pieces = ["", "a", "z", '"', "\\", "\n", "\t", "\u0001", "\u001f", "中文", "😀", "é", "\u2028", "\uffff"];
  const randText = () => Array.from({ length: rng.int(0, 4) }, () => rng.pick(pieces)).join("");
  const randJson = (depth = 0) => {
    const k = rng.int(0, depth > 2 ? 4 : 7);
    if (k === 0) return null;
    if (k === 1) return rng.next() < 0.5;
    if (k === 2) return rng.pick([0, -1, 1, 42, -999, 1.5, -0.25, 1000000]);
    if (k === 3 || k === 4) return randText();
    if (k === 5) return Array.from({ length: rng.int(0, 4) }, () => randJson(depth + 1));
    const obj = {};
    const n = rng.int(0, 4);
    for (let i = 0; i < n; i++) obj[randText()] = randJson(depth + 1);
    return obj;
  };
  const mutateJson = (v) => {
    if (rng.next() < 0.2) return randJson(1);
    if (Array.isArray(v)) {
      const m = rng.int(0, 3);
      if (m === 0) return [...v, randJson(2)]; // append
      if (m === 1 && v.length > 0) return v.map((x, i) => (i === rng.int(0, v.length - 1) ? mutateJson(x) : x));
      if (m === 2 && v.length > 0) return v.slice(0, v.length - 1);
      return [randJson(2), ...v];
    }
    if (v !== null && typeof v === "object") {
      const out = { ...v };
      const ks = Object.keys(out);
      if (ks.length > 0 && rng.next() < 0.4) delete out[rng.pick(ks)];
      if (ks.length > 0 && rng.next() < 0.5) {
        const k = rng.pick(ks);
        out[k] = mutateJson(out[k]);
      }
      if (rng.next() < 0.4) out[randText()] = randJson(2);
      return out;
    }
    return randJson(1);
  };

  for (let i = 0; i < 300; i++) {
    const oldV = randJson(0);
    const nextV = mutateJson(oldV);
    const tsOps = deltaTs.diff(oldV, nextV);
    const piOps = await rpc.call("delta.diff", { old: oldV, next: nextV });
    assert.deepEqual(piOps, tsOps, `fuzz delta.diff #${i}`);

    const tsApplied = deltaTs.apply(structuredClone(oldV), tsOps);
    const piApplied = await rpc.call("delta.apply", { value: oldV, ops: piOps });
    assert.deepEqual(piApplied, tsApplied, `fuzz delta.apply #${i}`);

    const tsLen = deltaTs.jsonLength(nextV);
    const piLen = await rpc.call("delta.jsonLength", { value: nextV });
    assert.equal(piLen, tsLen, `fuzz delta.jsonLength #${i}`);

    const lim = rng.int(0, tsLen + 2);
    assert.equal(
      (await rpc.call("delta.jsonLength", { value: nextV, limit: lim })) <= lim,
      deltaTs.jsonLength(nextV, lim) <= lim,
      `fuzz delta.jsonLength(limit=${lim}) #${i}`,
    );

    assert.equal(
      await rpc.call("delta.largerThan", { ops: tsOps, value: nextV }),
      deltaTs.largerThan(tsOps, nextV),
      `fuzz delta.largerThan #${i}`,
    );
    counts.moduleA += 5;
  }
});

// ---------------------------------------------------------------------------
// Module B: collections.ts vs packages/protocol/src/delta.pion
// ---------------------------------------------------------------------------
test("Module B: collections.ts (all SPECS, keyOf, diffKeyed, applyKeyed, heavier) — vectors + 200 seeded fuzz", async () => {
  // 1. All 23 SPECS topics + non-keyed topics
  const allTopics = [
    "chats", "chatSearch", "search", "chat", "archive", "chatRows", "archivedRows",
    "threads", "sessions", "jobs", "history", "chatOutline", "changelog", "vaults",
    "vaultItems", "driveTransfers", "downloads", "jobLog", "stations", "newChat",
    "stationMove", "profilesOverview", "workspaceMarks",
    // Non-keyed topics (must be null in both!)
    "accounts", "workspaces", "workspace", "lock", "presets", "otherPresets",
    "boardDrafts", "profiles", "fleet", "usage", "agentRates", "stationUpdates",
    "chatJobs", "longJobs", "settings", "unknownTopic",
  ];
  for (const topic of allTopics) {
    const tsSpec = collectionsTs.specOf({ topic });
    const piSpec = await rpc.call("collections.specOf", { topic });
    assert.deepEqual(piSpec, tsSpec, `specOf(${topic}) mismatch`);
    counts.moduleB++;
  }

  // 2. keyOf parity
  const keyOfCases = [
    [{ id: "a", station: "s1" }, ["id"]],
    [{ id: "a", station: "s1" }, ["station", "id"]],
    [{ id: "a" }, ["station", "id"]],
    [{ seq: 5, outgoing: true }, ["seq", "outgoing"]],
    [{ seq: 5 }, ["seq", "outgoing"]],
    [null, ["id"]],
    ["not-an-obj", ["a", "b"]],
  ];
  for (const [item, fields] of keyOfCases) {
    const tsK = collectionsTs.keyOf(item, fields);
    const piK = await rpc.call("collections.keyOf", { item, fields });
    assert.deepEqual(piK, tsK, `keyOf mismatch for ${JSON.stringify({ item, fields })}`);
    counts.moduleB++;
  }

  // 3. Nested multi-level keyed collections + duplicate key fallback + >256 fresh + >4096 heavier
  const row = (station, id, title = id, at = 1) => ({
    station, id, title, lastActiveAt: at, agents: [], unread: false,
  });
  const chatsVal = (days) => ({
    me: { email: "a@b.c" },
    loading: false,
    stations: [],
    days: days.map((d) => ({ ...d, at: d.daysAgo, label: `d${d.daysAgo}` })),
  });

  const rows50 = Array.from({ length: 50 }, (_, i) => row("ws/st", `t${i}`, `title-${i}-padding`));
  const nestedScenarios = [
    // chats: single row patch + move to top
    [
      "chats",
      chatsVal([{ daysAgo: 0, items: rows50 }]),
      chatsVal([{ daysAgo: 0, items: [{ ...rows50[30], lastActiveAt: 99 }, ...rows50.filter((_, i) => i !== 30)] }]),
    ],
    // chats: cross-day move + day drop + new day
    [
      "chats",
      chatsVal([{ daysAgo: 0, items: [row("ws/a", "1")] }, { daysAgo: 1, items: [row("ws/b", "1"), row("ws/a", "2")] }]),
      chatsVal([{ daysAgo: 1, items: [row("ws/b", "1")] }, { daysAgo: 3, items: [row("ws/a", "2"), row("ws/a", "1")] }]),
    ],
    // chatRows: duplicate key fallback to unkeyed diff
    [
      "chatRows",
      [row("s", "1", "a"), row("s", "1", "b")],
      [row("s", "1", "c")],
    ],
    // chatRows: >256 fresh items fallback to set
    [
      "chatRows",
      [row("s", "old1")],
      Array.from({ length: 270 }, (_, i) => row("s", `fresh-${i}`)),
    ],
    // changelog: 3-level nested keyed list
    [
      "changelog",
      {
        tabs: [
          { part: "station", days: [{ day: "2026-11-22", entries: [{ version: "0.1.1", text: "a" }, { version: "0.1.2", text: "b" }] }] },
        ],
      },
      {
        tabs: [
          { part: "station", days: [{ day: "2026-11-23", entries: [{ version: "0.1.3", text: "c" }] }, { day: "2026-11-22", entries: [{ version: "0.1.1", text: "a-edited" }, { version: "0.1.2", text: "b" }] }] },
        ],
      },
    ],
    // stationMove: modules[].items[]
    [
      "stationMove",
      { targets: [{ station: "s1", free: 100 }], modules: [{ id: "chats", items: [{ id: "c1", state: "wait" }, { id: "c2", state: "wait" }] }] },
      { targets: [{ station: "s1", free: 90 }], modules: [{ id: "chats", items: [{ id: "c1", state: "done" }, { id: "c3", state: "wait" }] }] },
    ],
    // workspaceMarks: map-valued item spec workspaces.*.items[]
    [
      "workspaceMarks",
      { workspaces: { ws1: { count: 2, items: [{ station: "s1", thread: 1, session: "a", title: "one" }, { station: "s1", thread: 2, session: "b", title: "two" }] } } },
      { workspaces: { ws1: { count: 2, items: [{ station: "s1", thread: 2, session: "b", title: "two-updated" }, { station: "s1", thread: 3, session: "c", title: "three" }] } } },
    ],
    // search: groups[].items[] + items + messages
    [
      "search",
      {
        items: [row("s1", "c1")],
        messages: [{ station: "s1", thread: 1, seq: 10, text: "hi" }],
        groups: [{ kind: "chat", items: [{ key: "k1", title: "a" }, { key: "k2", title: "b" }] }],
      },
      {
        items: [row("s1", "c1", "renamed")],
        messages: [{ station: "s1", thread: 1, seq: 10, text: "hi" }, { station: "s1", thread: 1, seq: 11, text: "yo" }],
        groups: [{ kind: "chat", items: [{ key: "k2", title: "b" }, { key: "k3", title: "c" }] }],
      },
    ],
  ];

  for (const [topic, oldV, nextV] of nestedScenarios) {
    const spec = collectionsTs.specOf({ topic });
    const tsOps = collectionsTs.diffKeyed(oldV, nextV, spec);
    const piOps = await rpc.call("collections.diffKeyed", { old: oldV, next: nextV, topic });
    assert.deepEqual(piOps, tsOps, `diffKeyed mismatch on topic=${topic}`);

    const tsApplied = collectionsTs.applyKeyed(oldV, tsOps);
    const piApplied = await rpc.call("collections.applyKeyed", { value: oldV, ops: piOps });
    assert.deepEqual(piApplied, tsApplied, `applyKeyed mismatch on topic=${topic}`);
    assert.deepEqual(piApplied, nextV, `roundtrip mismatch on topic=${topic}`);

    assert.equal(
      await rpc.call("collections.heavier", { ops: tsOps, value: nextV }),
      collectionsTs.heavier(tsOps, nextV),
      `heavier mismatch on topic=${topic}`,
    );
    counts.moduleB += 3;
  }

  // 4. 200 seeded random keyed mutation sequences (strict op-for-op equality!)
  const rng = makeRng(777123);
  for (let round = 0; round < 200; round++) {
    const len = rng.int(0, 15);
    const old = Array.from({ length: len }, (_, i) => row("s", `k${i}`, `t-${i}-${rng.int(0, 999)}`, rng.int(0, 100)));
    const next = old
      .filter(() => rng.int(0, 3) > 0)
      .map((r) => (rng.int(0, 2) === 0 ? { ...r, title: `x-${rng.int(0, 9999)}`, unread: rng.int(0, 1) === 1 } : r));
    for (let i = rng.int(0, 4); i > 0; i--) {
      next.splice(rng.int(0, next.length), 0, row("s", `n${round}-${i}`, `new-${i}`, rng.int(0, 100)));
    }
    for (let i = next.length - 1; i > 0; i--) {
      if (rng.int(0, 2) === 0) {
        const j = rng.int(0, i);
        [next[i], next[j]] = [next[j], next[i]];
      }
    }
    const spec = collectionsTs.specOf({ topic: "chatRows", station: "s" });
    const tsOps = collectionsTs.diffKeyed(old, next, spec);
    const piOps = await rpc.call("collections.diffKeyed", { old, next, topic: "chatRows" });
    assert.deepEqual(piOps, tsOps, `fuzz diffKeyed round ${round}`);

    const tsApplied = collectionsTs.applyKeyed(old, tsOps);
    const piApplied = await rpc.call("collections.applyKeyed", { value: old, ops: piOps });
    assert.deepEqual(piApplied, next, `fuzz applyKeyed roundtrip ${round}`);
    assert.deepEqual(piApplied, tsApplied, `fuzz applyKeyed parity ${round}`);
    counts.moduleB += 2;
  }
});

// ---------------------------------------------------------------------------
// Module C: protocol.ts + digest.ts vs packages/protocol/src/{protocol,delta}.pion
// ---------------------------------------------------------------------------
test("Module C: protocol.ts (all 103 TOPICS, parseClientMessage, topicKey, topicStation, isView) + digest.ts", async () => {
  const sampleValid = (kind, name) => {
    if (name === "part") return "updates";
    if (name === "groupBy") return "project";
    if (kind === "string") return `v-${name}`;
    if (kind === "bool") return true;
    if (kind === "object") return { z: 1, a: "x" };
    if (kind === "u16") return 65535;
    if (kind === "u32") return 4294967295;
    return 9007199254740991;
  };
  const sampleBad = (kind) => {
    if (kind === "string") return 123;
    if (kind === "bool") return "yes";
    if (kind === "object") return [1, 2];
    return -1;
  };

  // Test every single topic in TS TOPICS (all 103)
  for (const [topicName, spec] of Object.entries(protocolTs.TOPICS)) {
    // 1) Minimal valid (only req fields)
    const minRaw = { topic: topicName };
    // 2) Full valid (all fields populated)
    const fullRaw = { topic: topicName };
    for (const [fname, [kind, how]] of Object.entries(spec)) {
      const v = sampleValid(kind, fname);
      if (how === "req") minRaw[fname] = v;
      fullRaw[fname] = v;
    }

    for (const raw of [minRaw, fullRaw]) {
      const tsParsed = protocolTs.parseTopic(raw);
      const piParsed = await rpc.call("protocol.parseTopic", { raw });
      assert.deepEqual(piParsed, tsParsed, `parseTopic(${JSON.stringify(raw)})`);
      assert.ok(tsParsed !== null, `expected valid topic for ${topicName}`);

      assert.equal(
        await rpc.call("protocol.topicKey", { raw }),
        protocolTs.topicKey(tsParsed),
        `topicKey(${topicName})`,
      );
      assert.equal(
        await rpc.call("protocol.topicStation", { raw }),
        protocolTs.topicStation(tsParsed),
        `topicStation(${topicName})`,
      );
      assert.equal(
        await rpc.call("protocol.isView", { raw }),
        protocolTs.isView(tsParsed),
        `isView(${topicName})`,
      );
      counts.moduleC += 4;
    }

    // 3) Invalid field cases (missing req, wrong type, false on skipFalse)
    for (const [fname, [kind, how]] of Object.entries(spec)) {
      if (how === "req") {
        const missing = { ...minRaw };
        delete missing[fname];
        assert.deepEqual(
          await rpc.call("protocol.parseTopic", { raw: missing }),
          protocolTs.parseTopic(missing),
          `parseTopic missing req ${topicName}.${fname}`,
        );
        counts.moduleC++;
      }
      const badType = { ...minRaw, [fname]: sampleBad(kind) };
      assert.deepEqual(
        await rpc.call("protocol.parseTopic", { raw: badType }),
        protocolTs.parseTopic(badType),
        `parseTopic bad type ${topicName}.${fname}`,
      );
      counts.moduleC++;
      if (how === "skipFalse") {
        const withFalse = { ...minRaw, [fname]: false };
        assert.deepEqual(
          await rpc.call("protocol.parseTopic", { raw: withFalse }),
          protocolTs.parseTopic(withFalse),
          `parseTopic skipFalse=false ${topicName}.${fname}`,
        );
        counts.moduleC++;
      }
    }
  }

  // Extra topic edge cases: stationPart whitelist, u16/u32 overflow, unknown topic, non-object
  const topicEdges = [
    null, 42, "chats", [], {}, { topic: "nope" },
    { topic: "stationPart", scope: "ws", station: "ws/s", part: "invalidPart" },
    { topic: "stationPart", scope: "ws", station: "ws/s", part: "archiving" },
    { topic: "stationPart", scope: "ws", station: "ws/s", part: "copies" },
    { topic: "previewLoad", station: "ws/s", port: 65536 },
    { topic: "previewLoad", station: "ws/s", port: 80.5 },
    { topic: "archive", scope: "ws", limit: 4294967296 },
    { topic: "chat", station: "ws/s", thread: null, session: null },
  ];
  for (const raw of topicEdges) {
    assert.deepEqual(
      await rpc.call("protocol.parseTopic", { raw }),
      protocolTs.parseTopic(raw),
      `parseTopic edge ${JSON.stringify(raw)}`,
    );
    counts.moduleC++;
  }

  // parseClientMessage parity
  const clientMsgs = [
    null, 1, "hi", [], {},
    { id: -1, call: "x" },
    { id: 1.5, call: "x" },
    { id: "1", call: "x" },
    { id: 0, call: "ping" },
    { id: 1, call: "chat.send", params: { text: "hi" } },
    { id: 2, subscribe: { topic: "chats", scope: "ws" } },
    { id: 3, subscribe: { topic: "chats", scope: "ws" }, keyed: true, from: 2, have: "tok1" },
    { id: 4, subscribe: { topic: "chats", scope: "ws" }, keyed: true, from: 4 }, // from === id ignored
    { id: 5, subscribe: { topic: "chats", scope: "ws" }, keyed: false, from: 2, have: "tok2" }, // keyed !== true ignores from
    { id: 6, subscribe: { topic: "unknown" } },
    { id: 7, subscribe: { topic: "unknown" }, cancel: true }, // fallthrough to cancel!
    { id: 8, unsubscribe: true },
    { id: 9, unsubscribe: false, keep: true },
    { id: 10, cancel: true },
    { id: 11, cancel: "yes" },
  ];
  for (const raw of clientMsgs) {
    const tsOut = protocolTs.parseClientMessage(raw);
    const piOut = await rpc.call("protocol.parseClientMessage", { raw });
    assert.deepEqual(piOut, tsOut, `parseClientMessage(${JSON.stringify(raw)})`);
    counts.moduleC++;
  }

  // digest.ts parity: digest, version, textHash, and token (for primitives)
  const digestCases = [
    null, true, false, 0, -1, 42, 1.5, "", "hello", "中文测试", "😀🚀👨‍👩‍👧‍👦",
    'a"b\\c\n\t\u0001', [], [1, "a", null],
    { z: 1, a: 2, "😀": 3, "\uffff": 4, nested: { b: [true, false], a: "中文" } },
  ];
  const rng = makeRng(998877);
  const chars = ["a", "Z", "0", '"', "\\", "\n", "中", "😀", "\uffff", "é"];
  for (let i = 0; i < 100; i++) {
    const obj = {};
    for (let k = 0; k < rng.int(0, 6); k++) {
      const key = Array.from({ length: rng.int(1, 3) }, () => rng.pick(chars)).join("");
      obj[key] = rng.pick([null, true, false, rng.int(-1000, 1000), Array.from({ length: rng.int(0, 4) }, () => rng.pick(chars)).join("")]);
    }
    digestCases.push(obj);
  }
  for (const v of digestCases) {
    assert.equal(await rpc.call("digest.digest", { value: v }), digestTs.digest(v), `digest(${JSON.stringify(v)})`);
    assert.equal(await rpc.call("digest.version", { value: v }), digestTs.version(v), `version(${JSON.stringify(v)})`);
    assert.equal(await rpc.call("digest.valueToken", { value: v }), digestTs.version(v), `valueToken==version(${JSON.stringify(v)})`);
    if (v === null || typeof v !== "object") {
      assert.equal(await rpc.call("digest.valueToken", { value: v }), digestTs.token(v), `valueToken==token(${JSON.stringify(v)})`);
    }
    if (typeof v === "string") {
      assert.equal(await rpc.call("digest.textHash", { text: v }), digestTs.textHash(v), `textHash(${JSON.stringify(v)})`);
    }
    counts.moduleC += 3;
  }
});

// ---------------------------------------------------------------------------
// Module D: preset-records.ts + presets-kept.ts + board-drafts.ts
// ---------------------------------------------------------------------------
test("Module D: presets, stars, boardDrafts — vectors + 200 seeded fuzz", async () => {
  // 1. recordOf valid + invalid
  const validRecords = [
    { id: "p_1", owner: "u1", rev: 1, updatedAt: 100, gone: true },
    {
      id: "p-2", owner: "u1", rev: 2, updatedAt: 200, name: "  My Preset 😀  ",
      instructions: "  hello\nworld  ",
      dirs: [
        { path: "/a", repo: "", station: "ws/s1" },
        { path: "/a", repo: "ignored-dup", station: "ws/s1" },
        { path: "/b", repo: "org/repo", station: "ws/s2" },
      ],
      stations: ["  ws/s1 ", "ws/s1"],
      model: { model: " claude-opus-5-5 ", runtime: " claude ", effort: " high ", fast: true, tui: true, speed: "ultrafast", context: 200000, profile: " p1 ", profiles: [" a ", "b", "a"] },
      createdBy: "a@b.c", createdAt: 50, home: "s1",
    },
    {
      id: "p-3", owner: "", rev: 1, updatedAt: 0, name: "😀".repeat(60), // 60 codepoints (120 UTF-16 units)
      instructions: "", dirs: null, stations: ["ws/s1", "ws/s2"], autoStation: true,
      model: { model: "m", speed: "bogus", tui: false, context: 0 },
      home: "s1",
    },
    {
      id: "p-4", owner: "u1", rev: 1, updatedAt: 0, name: "Auto", autoStation: true, home: "s1",
    },
  ];
  for (const raw of validRecords) {
    const tsOut = presetRecordsTs.recordOf(raw);
    const piOut = await rpc.call("presets.recordOf", { raw });
    assert.deepEqual(piOut, tsOut, `recordOf valid ${raw.id}`);
    assert.equal(await rpc.call("presets.canonical", { value: tsOut }), presetRecordsTs.canonical(tsOut));
    counts.moduleD += 2;
  }

  const invalidRecords = [
    null, [], {},
    { id: "bad id!", owner: "u", rev: 1, updatedAt: 0, gone: true },
    { id: "p1", owner: "u", rev: 0, updatedAt: 0, gone: true },
    { id: "p1", owner: "u", rev: 1.5, updatedAt: 0, gone: true },
    { id: "p1", owner: "u", rev: 1, updatedAt: -1, gone: true },
    { id: "p1", owner: "u", rev: 1, updatedAt: 0, name: "   ", home: "s1" },
    { id: "p1", owner: "u", rev: 1, updatedAt: 0, name: "😀".repeat(61), home: "s1" },
    { id: "p1", owner: "u", rev: 1, updatedAt: 0, name: "ok", dirs: "not-arr", home: "s1" },
    { id: "p1", owner: "u", rev: 1, updatedAt: 0, name: "ok", dirs: [{ path: "", station: "s" }], home: "s1" },
    { id: "p1", owner: "u", rev: 1, updatedAt: 0, name: "ok", dirs: [{ path: "/a", station: "" }], home: "s1" },
    { id: "p1", owner: "u", rev: 1, updatedAt: 0, name: "ok", home: "" },
  ];
  for (const raw of invalidRecords) {
    let tsErr = null;
    try { presetRecordsTs.recordOf(raw); } catch (e) { tsErr = e.message; }
    assert.ok(tsErr !== null, `expected TS recordOf to reject ${JSON.stringify(raw)}`);
    const piResp = await rpc.callRaw("presets.recordOf", { raw });
    assert.equal(piResp.err, tsErr, `recordOf err mismatch for ${JSON.stringify(raw)}`);
    counts.moduleD++;
  }

  // 2. starsOf valid + invalid
  const validStars = [
    {},
    { "claude/opus": { on: true, rev: 1, at: 0 }, "gpt/sol": { on: false, rev: 3, at: 999 } },
  ];
  for (const raw of validStars) {
    assert.deepEqual(await rpc.call("stars.starsOf", { raw }), presetRecordsTs.starsOf(raw));
    counts.moduleD++;
  }
  const invalidStars = [
    null, [],
    { "": { on: true, rev: 1, at: 0 } },
    { m: { on: "yes", rev: 1, at: 0 } },
    { m: { on: true, rev: 0, at: 0 } },
    { m: { on: true, rev: 1, at: -1 } },
    Object.fromEntries(Array.from({ length: 201 }, (_, i) => [`m${i}`, { on: true, rev: 1, at: i }])),
  ];
  for (const raw of invalidStars) {
    let tsErr = null;
    try { presetRecordsTs.starsOf(raw); } catch (e) { tsErr = e.message; }
    const piResp = await rpc.callRaw("stars.starsOf", { raw });
    assert.equal(piResp.err, tsErr, `starsOf err mismatch`);
    counts.moduleD++;
  }

  // 3. draftOf valid + invalid
  const validDrafts = [
    { id: "new:board-1.a_b", owner: "u1", rev: 1, updatedAt: 100, gone: true },
    {
      id: "d:1", owner: "u1", rev: 2, at: 500, updatedAt: 600, title: "  Fix bug  ",
      station: "ws/s1", stationName: "Mac",
      files: [{ id: "f:1", name: "a.png", size: 123 }, { id: "f:1", name: "dup.png", size: 999 }, { id: "f:2", name: "b.txt" }],
    },
    { id: "d:2", owner: "u1", rev: 1, at: 10, updatedAt: 10, title: "", station: "ws/s1", files: [{ id: "f1", name: "x", size: 0 }] },
  ];
  for (const raw of validDrafts) {
    assert.deepEqual(await rpc.call("drafts.draftOf", { raw }), boardDraftsTs.draftOf(raw));
    counts.moduleD++;
  }
  const invalidDrafts = [
    null, [], {},
    { id: "bad id", owner: "u1", rev: 1, updatedAt: 0, gone: true },
    { id: "d1", owner: "", rev: 1, updatedAt: 0, gone: true },
    { id: "d1", owner: "u1", rev: 1, at: 0, updatedAt: 0, title: "   ", files: [], station: "ws/s1" },
    { id: "d1", owner: "u1", rev: 1, at: 0, updatedAt: 0, title: "hi", station: "" },
    { id: "d1", owner: "u1", rev: 1, at: 0, updatedAt: 0, title: "hi", station: "ws/s1", files: [{ id: "f1", name: "" }] },
  ];
  for (const raw of invalidDrafts) {
    let tsErr = null;
    try { boardDraftsTs.draftOf(raw); } catch (e) { tsErr = e.message; }
    const piResp = await rpc.callRaw("drafts.draftOf", { raw });
    assert.equal(piResp.err, tsErr, `draftOf err mismatch`);
    counts.moduleD++;
  }

  // 4. Eviction stress (>200 gone presets, >200 stars, >200 live + >200 gone drafts)
  const rng = makeRng(424242);
  const manyGone = Array.from({ length: 240 }, (_, i) => ({
    id: `g-${i}`, owner: i % 3 === 0 ? "alice" : "bob", rev: rng.int(1, 5), gone: true, updatedAt: rng.int(1, 50),
  }));
  assert.deepEqual(await rpc.call("presets.goneKept", { gone: manyGone }), presetRecordsTs.goneKept(manyGone));
  const manyRecMap = Object.fromEntries(
    Array.from({ length: 230 }, (_, i) => [
      `g-${i}`,
      { id: `g-${i}`, owner: "alice", rev: rng.int(1, 4), gone: true, updatedAt: rng.int(1, 40) },
    ]),
  );
  assert.deepEqual(await rpc.call("presets.recordsKept", { records: manyRecMap }), presetRecordsTs.recordsKept(manyRecMap));

  const starsA = Object.fromEntries(Array.from({ length: 150 }, (_, i) => [`m-${i}`, { on: i % 2 === 0, rev: rng.int(1, 3), at: rng.int(0, 100) }]));
  const starsB = Object.fromEntries(Array.from({ length: 150 }, (_, i) => [`m-${i + 80}`, { on: i % 3 === 0, rev: rng.int(1, 3), at: rng.int(0, 100) }]));
  assert.deepEqual(await rpc.call("stars.mergeStars", { kept: starsA, given: starsB }), presetRecordsTs.mergeStars(starsA, starsB));

  const keptDrafts = Object.fromEntries(
    Array.from({ length: 180 }, (_, i) => [
      `d-${i}`,
      { id: `d-${i}`, owner: "alice", rev: 1, at: rng.int(1, 500), updatedAt: rng.int(1, 500), title: `t${i}`, station: "ws/s1", stationName: "S1", files: [] },
    ]),
  );
  const givenDrafts = [
    ...Array.from({ length: 60 }, (_, i) => ({
      id: `d-${150 + i}`, owner: "alice", rev: rng.int(1, 3), at: rng.int(1, 500), updatedAt: rng.int(1, 500), title: `n${i}`, station: "ws/s1", stationName: "S1", files: [],
    })),
    ...Array.from({ length: 220 }, (_, i) => ({
      id: `gd-${i}`, owner: "alice", rev: rng.int(1, 3), gone: true, updatedAt: rng.int(1, 100),
    })),
  ];
  const tsMergedDrafts = boardDraftsTs.mergeDrafts(keptDrafts, givenDrafts);
  const piMergedDrafts = await rpc.call("drafts.mergeDrafts", { kept: keptDrafts, given: givenDrafts });
  assert.deepEqual(piMergedDrafts, tsMergedDrafts, "mergeDrafts eviction >200 live + >200 gone");
  assert.deepEqual(await rpc.call("drafts.liveDrafts", { drafts: tsMergedDrafts }), boardDraftsTs.liveDrafts(tsMergedDrafts));
  counts.moduleD += 5;

  // 5. 200 seeded random concurrent merge / lacking / newer fuzz rounds
  for (let round = 0; round < 200; round++) {
    // Presets newerRecord & lacking
    const mkPreset = (id) =>
      rng.next() < 0.3
        ? { id, owner: "u1", rev: rng.int(1, 3), gone: true, updatedAt: rng.int(1, 5) }
        : {
            id, owner: "u1", rev: rng.int(1, 3), updatedAt: rng.int(1, 5),
            name: rng.pick(["Alpha", "Beta", "😀", "\uffff"]),
            dirs: [], instructions: rng.pick(["", "x", "y"]),
            createdBy: "u@e.c", createdAt: 1, home: "s1",
          };
    const pa = mkPreset("p1");
    const pb = mkPreset("p1");
    assert.deepEqual(await rpc.call("presets.newerRecord", { a: pa, b: pb }), presetRecordsTs.newerRecord(pa, pb), `fuzz newerRecord #${round}`);

    const recMapA = Object.fromEntries(["p1", "p2", "p3"].map((id) => [id, mkPreset(id)]));
    const recMapB = Object.fromEntries(["p1", "p2"].map((id) => [id, mkPreset(id)]));
    assert.deepEqual(
      await rpc.call("presets.recordsLacking", { records: recMapA, said: recMapB, sub: "u1" }),
      presetsKeptTs.lacking(recMapA, new Map(Object.entries(recMapB)), { sub: "u1", email: "u@e.c" }),
      `fuzz recordsLacking #${round}`,
    );

    // Stars newerStar, mergeStars, starsLacking
    const sa = { on: rng.next() < 0.5, rev: rng.int(1, 3), at: rng.int(1, 5) };
    const sb = { on: rng.next() < 0.5, rev: rng.int(1, 3), at: rng.int(1, 5) };
    assert.deepEqual(await rpc.call("stars.newerStar", { a: sa, b: sb }), presetRecordsTs.newerStar(sa, sb), `fuzz newerStar #${round}`);
    const smA = { a: sa, "😀": sb };
    const smB = { a: sb, "\uffff": sa };
    assert.deepEqual(await rpc.call("stars.mergeStars", { kept: smA, given: smB }), presetRecordsTs.mergeStars(smA, smB), `fuzz mergeStars #${round}`);
    assert.deepEqual(await rpc.call("stars.starsLacking", { stars: smA, said: smB }), presetsKeptTs.starsLacking(smA, smB), `fuzz starsLacking #${round}`);

    // Drafts newerDraft, mergeDrafts, draftsLacking, liveDrafts
    const mkDraft = (id) =>
      rng.next() < 0.35
        ? { id, owner: "u1", rev: rng.int(1, 3), gone: true, updatedAt: rng.int(1, 5) }
        : { id, owner: "u1", rev: rng.int(1, 3), at: rng.int(1, 5), updatedAt: rng.int(1, 5), title: rng.pick(["a", "b", "😀"]), station: "ws/s1", stationName: "S1", files: [] };
    const da = mkDraft("d1");
    const db = mkDraft("d1");
    assert.deepEqual(await rpc.call("drafts.newerDraft", { a: da, b: db }), boardDraftsTs.newerDraft(da, db), `fuzz newerDraft #${round}`);
    const dmA = { d1: da, d2: mkDraft("d2") };
    const dmB = { d1: db, d3: mkDraft("d3") };
    const gList = [db, mkDraft("d2"), mkDraft("d3")];
    assert.deepEqual(await rpc.call("drafts.mergeDrafts", { kept: dmA, given: gList }), boardDraftsTs.mergeDrafts(dmA, gList), `fuzz mergeDrafts #${round}`);
    assert.deepEqual(await rpc.call("drafts.draftsLacking", { drafts: dmA, said: dmB }), boardDraftsTs.draftsLacking(dmA, dmB), `fuzz draftsLacking #${round}`);
    assert.deepEqual(await rpc.call("drafts.liveDrafts", { drafts: dmA }), boardDraftsTs.liveDrafts(dmA), `fuzz liveDrafts #${round}`);
    counts.moduleD += 9;
  }
});

// ---------------------------------------------------------------------------
// Module E: lock.ts canonical + vault/crypto.ts + vault-vectors.json + views/pair.ts admitOf
// ---------------------------------------------------------------------------
test("Module E: lock canonical, vault allows, bidirectional crypto, vault-vectors.json, pair admitOf", async () => {
  // 1. lock.ts canonical vs Pion form::canonical
  const canonCases = [
    null, true, false, 0, -1, 42, 9007199254740991, -9007199254740991,
    "", 'a"b\\c\b\f\n\r\t\u0000\u001f', "中文 😀",
    [], [1, "a", null, true, { z: 1, a: 2 }],
    { b: 1, a: 2, "😀": 3, "\uffff": 4, nested: { k2: -5, k1: [0, 1] } },
    1.5, // must fail in both!
  ];
  const rng = makeRng(314159);
  const keysPool = ["a", "b", "z", "中文", "😀", "\uffff", 'q"w'];
  for (let i = 0; i < 100; i++) {
    const obj = {};
    for (let j = 0; j < rng.int(0, 5); j++) {
      obj[rng.pick(keysPool)] = rng.pick([null, true, false, rng.int(-100000, 100000), rng.pick(keysPool), [1, 2]]);
    }
    canonCases.push(obj);
  }
  for (const v of canonCases) {
    let tsOut = null;
    let tsErr = false;
    try { tsOut = lockTs.canonical(v); } catch { tsErr = true; }
    const piResp = await rpc.callRaw("lock.canonical", { value: v });
    if (tsErr) {
      assert.ok("err" in piResp, `expected lock.canonical err on ${JSON.stringify(v)}`);
    } else {
      assert.equal(piResp.ok, tsOut, `lock.canonical mismatch on ${JSON.stringify(v)}`);
    }
    counts.moduleE++;
  }

  // 2. vault/crypto.ts allows(lasts, scope) full matrix
  const lastsVals = [null, "once", "hour", "chat", "bad", ""];
  const scopeVals = ["once", "hour", "chat", "bad", ""];
  for (const lasts of lastsVals) {
    for (const scope of scopeVals) {
      assert.equal(
        await rpc.call("vault.allows", { lasts, scope }),
        vaultCryptoTs.allows(lasts, scope),
        `allows(${lasts}, ${scope})`,
      );
      counts.moduleE++;
    }
  }

  // 3. Bidirectional cross-engine sealWith/openSeal & encryptWith/decrypt (30 random rounds)
  for (let i = 0; i < 30; i++) {
    const priv = rng.bytes(32);
    const eph = rng.bytes(32);
    const key = rng.bytes(32);
    const nonce = rng.bytes(12);
    const plain = rng.bytes(rng.int(0, 256));
    const context = `ctx/${i}\u0000${rng.pick(["ascii", "中文", "😀"])}`;

    const tsPub = vaultCryptoTs.boxPublic(priv);
    const piPub = await rpc.call("vault.boxPublic", { privHex: toHex(priv) });
    assert.equal(piPub, tsPub, `boxPublic #${i}`);

    // TS sealWith -> Pion openSeal, and Pion sealWith -> TS openSeal (and identical ciphertext!)
    const tsSealed = vaultCryptoTs.sealWith(tsPub, plain, context, eph);
    const piSealed = await rpc.call("vault.sealWith", { pub: tsPub, plainHex: toHex(plain), context, ephHex: toHex(eph) });
    assert.equal(piSealed, tsSealed, `sealWith ciphertext #${i}`);

    const piOpenedHex = await rpc.call("vault.openSeal", { privHex: toHex(priv), sealed: tsSealed, context });
    assert.equal(piOpenedHex, toHex(plain), `TS sealWith -> Pion openSeal #${i}`);

    const tsOpened = vaultCryptoTs.openSeal(priv, piSealed, context);
    assert.equal(toHex(tsOpened), toHex(plain), `Pion sealWith -> TS openSeal #${i}`);

    // Wrong context must fail in both
    assert.throws(() => vaultCryptoTs.openSeal(priv, piSealed, context + "!"));
    const badSealResp = await rpc.callRaw("vault.openSeal", { privHex: toHex(priv), sealed: tsSealed, context: context + "!" });
    assert.ok("err" in badSealResp, `expected openSeal wrong context fail #${i}`);

    // TS encryptWith -> Pion decrypt, and Pion encryptWith -> TS decrypt
    const tsCt = vaultCryptoTs.encryptWith(key, plain, context, nonce);
    const piCt = await rpc.call("vault.encryptWith", { keyHex: toHex(key), plainHex: toHex(plain), context, nonceHex: toHex(nonce) });
    assert.equal(piCt, tsCt, `encryptWith ciphertext #${i}`);

    const piDecHex = await rpc.call("vault.decrypt", { keyHex: toHex(key), ct: tsCt, context });
    assert.equal(piDecHex, toHex(plain), `TS encryptWith -> Pion decrypt #${i}`);

    const tsDec = vaultCryptoTs.decrypt(key, piCt, context);
    assert.equal(toHex(tsDec), toHex(plain), `Pion encryptWith -> TS decrypt #${i}`);

    // Wrong context must fail in both
    assert.throws(() => vaultCryptoTs.decrypt(key, piCt, context + "!"));
    const badDecResp = await rpc.callRaw("vault.decrypt", { keyHex: toHex(key), ct: tsCt, context: context + "!" });
    assert.ok("err" in badDecResp, `expected decrypt wrong context fail #${i}`);
    counts.moduleE += 8;
  }

  // 4. station/test/fixtures/vault-vectors.json full cross-verification
  const vec = JSON.parse(fs.readFileSync(path.join(repoRoot, "station/test/fixtures/vault-vectors.json"), "utf8"));
  assert.equal(await rpc.call("vault.boxPublic", { privHex: vec.box.priv }), vec.box.pub);
  assert.equal(vaultCryptoTs.boxPublic(fromHex(vec.box.priv)), vec.box.pub);
  assert.equal(await rpc.call("vault.boxPublic", { privHex: vec.requestBox.priv }), vec.requestBox.pub);

  for (const rec of vec.recovery) {
    const tsRec = vaultCryptoTs.recoveryPair(fromHex(rec.entropy));
    const piRec = await rpc.call("vault.recoveryPair", { entropyHex: rec.entropy });
    assert.equal(tsRec.pub, rec.pub);
    assert.equal(piRec.pub, rec.pub);
    assert.equal(piRec.privHex, toHex(tsRec.priv));
    counts.moduleE++;
  }

  const keyCtx = vaultCryptoTs.keyContext(vec.ws, vec.vault.id, vec.vault.epoch);
  assert.equal(
    await rpc.call("vault.sealWith", { pub: vec.box.pub, plainHex: vec.vaultKey, context: keyCtx, ephHex: vec.eph.wrap }),
    vec.vault.keys[0].wrapped,
  );
  assert.equal(
    await rpc.call("vault.openSeal", { privHex: vec.box.priv, sealed: vec.vault.keys[0].wrapped, context: keyCtx }),
    vec.vaultKey,
  );
  assert.equal(
    await rpc.call("vault.sealWith", { pub: vec.recovery[1].pub, plainHex: vec.vaultKey, context: keyCtx, ephHex: vec.eph.recovery }),
    vec.vault.recovery,
  );
  const rec1Priv = vaultCryptoTs.recoveryPair(fromHex(vec.recovery[1].entropy)).priv;
  assert.equal(
    await rpc.call("vault.openSeal", { privHex: toHex(rec1Priv), sealed: vec.vault.recovery, context: keyCtx }),
    vec.vaultKey,
  );
  const itemCtx = vaultCryptoTs.itemContext(vec.ws, vec.vault.id, vec.item.id, vec.item.version, vec.item.epoch);
  const plainHex = Buffer.from(vec.plain, "utf8").toString("hex");
  assert.equal(
    await rpc.call("vault.encryptWith", { keyHex: vec.vaultKey, plainHex, context: itemCtx, nonceHex: vec.nonce }),
    vec.item.ct,
  );
  assert.equal(
    await rpc.call("vault.decrypt", { keyHex: vec.vaultKey, ct: vec.item.ct, context: itemCtx }),
    plainHex,
  );
  const grantCtx = vaultCryptoTs.grantContext(vec.ws, vec.grant.request);
  assert.equal(
    await rpc.call("vault.sealWith", { pub: vec.requestBox.pub, plainHex, context: grantCtx, ephHex: vec.eph.grant }),
    vec.grant.secret,
  );
  assert.equal(
    await rpc.call("vault.openSeal", { privHex: vec.requestBox.priv, sealed: vec.grant.secret, context: grantCtx }),
    plainHex,
  );

  // Verify Ed25519 signing of cert, vault, item, grant, deny against vault-vectors.json + TS sign()
  const signerSeed = fromHex(vec.signer.seed);
  const tsSigner = {
    id: vec.signer.key,
    signBytes: (bytes) => toHex(ed25519.sign(bytes, signerSeed)),
  };
  for (const [kind, record] of [
    ["box", vec.cert],
    ["vault", vec.vault],
    ["item", vec.item],
    ["grant", vec.grant],
    ["deny", vec.deny],
  ]) {
    const { sig: _, ...unsigned } = record;
    const tsSigned = vaultCryptoTs.sign(unsigned, vaultCryptoTs.TAG[kind], tsSigner);
    const piSigned = await rpc.call("vault.sign", { seedHex: vec.signer.seed, tag: vaultCryptoTs.TAG[kind], record: unsigned });
    assert.deepEqual(tsSigned.sig, record.sig, `TS sign ${kind} vs fixture`);
    assert.deepEqual(piSigned.sig, record.sig, `Pion sign ${kind} vs fixture`);
    counts.moduleE += 2;
  }

  // 5. views/pair.ts admitOf role capping full combinatorial matrix (750 combinations)
  // Exact TS model of `views/pair.ts admitOf` + `role::may` (MemberRemove(was_owner), MemberSet(was_owner, becomes_owner))
  const RANKS = ["viewer", "member", "admin", "owner"];
  const lower = (a, b) => (RANKS.indexOf(a) <= RANKS.indexOf(b) ? a : b);
  const tsMovedPlanOk = (actor, existing, target) => {
    if (actor !== "owner" && actor !== "admin") return false;
    if (!RANKS.includes(target)) return false;
    const wasOwner = existing === "owner";
    if (actor === "admin" && (wasOwner || target === "owner")) return false;
    return true;
  };
  const tsAdmitOfRole = (actor, noted, existing, viewed) => {
    if (actor !== "owner" && actor !== "admin") return null;
    if (!RANKS.includes(viewed)) return null;
    if (!tsMovedPlanOk(actor, existing, viewed)) return null;
    if (noted !== null && !tsMovedPlanOk(actor, existing, noted)) return null;
    const chosen = noted ?? (existing !== null && RANKS.includes(existing) ? existing : "member");
    const finalRole = lower(chosen, viewed);
    return tsMovedPlanOk(actor, existing, finalRole) ? finalRole : null;
  };

  const actors = ["owner", "admin", "member", "viewer", "bad"];
  const noteds = [null, "owner", "admin", "member", "viewer", "bad"];
  const existings = [null, "owner", "admin", "member", "viewer"];
  const clouds = ["owner", "admin", "member", "viewer", "bad"];

  for (const noted of noteds) {
    for (const cloud of clouds) {
      const tsSimple = !RANKS.includes(cloud) || (noted !== null && !RANKS.includes(noted))
        ? null
        : lower(noted ?? "member", cloud);
      assert.equal(
        await rpc.call("pair.admitMemberRole", { noted, cloud }),
        tsSimple,
        `admitMemberRole(${noted}, ${cloud})`,
      );
      counts.moduleE++;
    }
  }
  for (const actor of actors) {
    for (const noted of noteds) {
      for (const existing of existings) {
        for (const cloud of clouds) {
          const tsRole = tsAdmitOfRole(actor, noted, existing, cloud);
          const piRole = await rpc.call("pair.admitMemberRoleByActor", { actor, noted, existing, cloud });
          assert.equal(piRole, tsRole, `admitMemberRoleByActor(${actor}, ${noted}, ${existing}, ${cloud})`);
          counts.moduleE++;
        }
      }
    }
  }
});
