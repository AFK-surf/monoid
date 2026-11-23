// Real `apps/mbui` `sfreplay` recording protocol & keyed-delta differential parity audit.
// Scans every real recording in `apps/mbui/e2e/traces/*.trace` and `apps/mbui/e2e/tapes/*.trace`,
// drives the compiled native `pion/client-core/packages/parity_cli` binary over JSONL RPC, and
// asserts 0 diffs against `client/core-ts/src/{protocol,collections,digest}.ts` plus validates
// `pion/client-core/scripts/coverage-ledger.mjs --json`.

import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { after, before, test } from "node:test";
import { fileURLToPath } from "node:url";

import * as collectionsTs from "../../../client/core-ts/src/collections.ts";
import * as digestTs from "../../../client/core-ts/src/digest.ts";
import * as opsTs from "../../../client/core-ts/src/ops.ts";
import * as protocolTs from "../../../client/core-ts/src/protocol.ts";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, "../../..");
const pioncBin = process.env.PIONC || path.join(os.homedir(), ".pion/bin/pionc");

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

const stats = {
  traceFiles: 0,
  tapeFiles: 0,
  clientMessagesChecked: 0,
  subscribesChecked: 0,
  callsChecked: 0,
  unsubscribesChecked: 0,
  cancelsChecked: 0,
  keyedInitialSnapshotsChecked: 0,
  keyedPairsChecked: 0,
  keyedPairsByTopic: {},
};

before(() => {
  builtBin = path.join(os.tmpdir(), `pion-client-core-sfreplay-parity-${process.pid}`);
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
    try {
      fs.unlinkSync(builtBin);
    } catch {}
  }
  console.log("sfreplay audit summary (0 diffs):", stats);
});

/**
 * Load all real `ClientMessage` records and consecutive keyed-topic snapshots from
 * `apps/mbui/e2e/traces/*.trace` and `apps/mbui/e2e/tapes/*.trace`.
 */
function loadRealSfreplayCorpus() {
  const tracesDir = path.join(repoRoot, "apps/mbui/e2e/traces");
  const tapesDir = path.join(repoRoot, "apps/mbui/e2e/tapes");

  const traceFiles = fs.readdirSync(tracesDir).filter((f) => f.endsWith(".trace")).sort();
  const tapeFiles = fs.readdirSync(tapesDir).filter((f) => f.endsWith(".trace")).sort();

  const clientMessages = []; // { source, raw }
  const keyedInitials = []; // { source, topic, value }
  const keyedPairs = []; // { source, topic, prev, next }

  // 1. JSONL full core traces (`out` and `in` frames)
  for (const file of traceFiles) {
    const source = `traces/${file}`;
    const lines = fs.readFileSync(path.join(tracesDir, file), "utf8").split("\n");
    const subTopics = new Map(); // id -> topicName
    const lastVal = new Map(); // id -> snapshot value

    for (const line of lines) {
      if (!line.trim()) continue;
      const obj = JSON.parse(line);
      if (obj.out && typeof obj.out === "object") {
        clientMessages.push({ source, raw: obj.out });
        const parsed = protocolTs.parseClientMessage(obj.out);
        if (!("invalid" in parsed)) {
          if (parsed.kind === "subscribe") {
            subTopics.set(parsed.id, parsed.subscribe.topic);
          } else if (parsed.kind === "unsubscribe") {
            subTopics.delete(parsed.id);
            lastVal.delete(parsed.id);
          }
        }
      }
      if (obj.in && typeof obj.in === "object") {
        const msg = obj.in;
        const topic = subTopics.get(msg.id);
        if (!topic || !collectionsTs.specOf({ topic })) continue;

        if ("value" in msg) {
          if (lastVal.has(msg.id)) {
            keyedPairs.push({ source, topic, prev: lastVal.get(msg.id), next: msg.value });
          } else {
            keyedInitials.push({ source, topic, value: msg.value });
          }
          lastVal.set(msg.id, msg.value);
        } else if ("delta" in msg && lastVal.has(msg.id)) {
          const prev = lastVal.get(msg.id);
          const next = collectionsTs.applyKeyed(structuredClone(prev), msg.delta);
          keyedPairs.push({ source, topic, prev, next });
          lastVal.set(msg.id, next);
        }
      }
    }
  }

  // 2. JSON motion tapes (`topics` initial values + `events` set/call updates)
  for (const file of tapeFiles) {
    const source = `tapes/${file}`;
    const tape = JSON.parse(fs.readFileSync(path.join(tapesDir, file), "utf8"));
    let synthId = 1;
    const topicLastVal = new Map(); // topicKey -> value

    for (const entry of tape.topics || []) {
      if (!entry?.topic) continue;
      const rawSub = { id: synthId++, subscribe: entry.topic, keyed: true };
      clientMessages.push({ source, raw: rawSub });
      const parsedTopic = protocolTs.parseTopic(entry.topic);
      if (parsedTopic && collectionsTs.specOf(parsedTopic) && "value" in entry) {
        const tk = protocolTs.topicKey(parsedTopic);
        keyedInitials.push({ source, topic: parsedTopic.topic, value: entry.value });
        topicLastVal.set(tk, entry.value);
      }
    }

    for (const ev of tape.events || []) {
      if (ev?.set && typeof ev.set === "object") {
        const rawSub = { id: synthId++, subscribe: ev.set, keyed: true };
        clientMessages.push({ source, raw: rawSub });
        const parsedTopic = protocolTs.parseTopic(ev.set);
        if (parsedTopic && collectionsTs.specOf(parsedTopic) && "value" in ev) {
          const tk = protocolTs.topicKey(parsedTopic);
          if (topicLastVal.has(tk)) {
            keyedPairs.push({ source, topic: parsedTopic.topic, prev: topicLastVal.get(tk), next: ev.value });
          } else {
            keyedInitials.push({ source, topic: parsedTopic.topic, value: ev.value });
          }
          topicLastVal.set(tk, ev.value);
        }
      }
      if (typeof ev?.call === "string") {
        const rawCall = { id: synthId++, call: ev.call, params: ev.params ?? null };
        clientMessages.push({ source, raw: rawCall });
      }
    }
  }

  return { traceFiles, tapeFiles, clientMessages, keyedInitials, keyedPairs };
}

const corpus = loadRealSfreplayCorpus();
stats.traceFiles = corpus.traceFiles.length;
stats.tapeFiles = corpus.tapeFiles.length;

test("1. Real sfreplay ClientMessages: TS protocol.ts vs Pion parity_cli (0 diffs)", async () => {
  assert.ok(corpus.traceFiles.length >= 80, `expected >= 80 e2e traces, got ${corpus.traceFiles.length}`);
  assert.ok(corpus.clientMessages.length > 3000, `expected > 3000 ClientMessages, got ${corpus.clientMessages.length}`);

  for (const { source, raw } of corpus.clientMessages) {
    const tsMsg = protocolTs.parseClientMessage(raw);
    const piMsg = await rpc.call("protocol.parseClientMessage", { raw });
    assert.deepEqual(piMsg, tsMsg, `parseClientMessage mismatch in ${source}: ${JSON.stringify(raw)}`);
    stats.clientMessagesChecked++;

    if (!("invalid" in tsMsg)) {
      if (tsMsg.kind === "subscribe") {
        stats.subscribesChecked++;
        const tsTopic = protocolTs.parseTopic(raw.subscribe);
        const piTopic = await rpc.call("protocol.parseTopic", { raw: raw.subscribe });
        assert.deepEqual(piTopic, tsTopic, `parseTopic mismatch in ${source}: ${JSON.stringify(raw.subscribe)}`);

        const tsKey = protocolTs.topicKey(tsTopic);
        const piKey = await rpc.call("protocol.topicKey", { raw: raw.subscribe });
        assert.equal(piKey, tsKey, `topicKey mismatch in ${source}: ${JSON.stringify(raw.subscribe)}`);

        const tsStation = protocolTs.topicStation(tsTopic);
        const piStation = await rpc.call("protocol.topicStation", { raw: raw.subscribe });
        assert.equal(piStation, tsStation, `topicStation mismatch in ${source}: ${JSON.stringify(raw.subscribe)}`);

        const tsIsView = protocolTs.isView(tsTopic);
        const piIsView = await rpc.call("protocol.isView", { raw: raw.subscribe });
        assert.equal(piIsView, tsIsView, `isView mismatch in ${source}: ${JSON.stringify(raw.subscribe)}`);
      } else if (tsMsg.kind === "call") {
        stats.callsChecked++;
      } else if (tsMsg.kind === "unsubscribe") {
        stats.unsubscribesChecked++;
      } else if (tsMsg.kind === "cancel") {
        stats.cancelsChecked++;
      }
    }
  }
});

test("2. Real sfreplay consecutive keyed snapshots: TS collections.ts + digest.ts vs Pion parity_cli (0 diffs)", async () => {
  assert.ok(corpus.keyedPairs.length > 500, `expected > 500 real keyed snapshot pairs, got ${corpus.keyedPairs.length}`);

  // Verify specOf parity for every keyed topic seen in sfreplay
  const seenKeyedTopics = new Set([
    ...corpus.keyedInitials.map((x) => x.topic),
    ...corpus.keyedPairs.map((x) => x.topic),
  ]);
  for (const topic of seenKeyedTopics) {
    const tsSpec = collectionsTs.specOf({ topic });
    const piSpec = await rpc.call("collections.specOf", { topic });
    assert.deepEqual(piSpec, tsSpec, `specOf mismatch for topic=${topic}`);
  }

  // Verify digest.version parity on initial keyed snapshots
  for (const { source, topic, value } of corpus.keyedInitials) {
    const tsVer = digestTs.version(value);
    const piVer = await rpc.call("digest.version", { value });
    assert.equal(piVer, tsVer, `initial digest.version mismatch on ${source} topic=${topic}`);
    stats.keyedInitialSnapshotsChecked++;
  }

  // Verify diffKeyed + applyKeyed + digest.version parity on every consecutive snapshot pair
  for (const { source, topic, prev, next } of corpus.keyedPairs) {
    const spec = collectionsTs.specOf({ topic });
    assert.ok(spec, `missing spec for keyed topic ${topic}`);

    const tsOps = collectionsTs.diffKeyed(prev, next, spec);
    const piOps = await rpc.call("collections.diffKeyed", { old: prev, next, topic });
    assert.deepEqual(piOps, tsOps, `diffKeyed mismatch on ${source} topic=${topic}`);

    const tsApplied = collectionsTs.applyKeyed(structuredClone(prev), tsOps);
    const piApplied = await rpc.call("collections.applyKeyed", { value: prev, ops: tsOps });
    assert.deepEqual(piApplied, tsApplied, `applyKeyed mismatch on ${source} topic=${topic}`);
    assert.deepEqual(piApplied, next, `applyKeyed did not reconstruct next on ${source} topic=${topic}`);

    const tsVer = digestTs.version(next);
    const piVer = await rpc.call("digest.version", { value: next });
    assert.equal(piVer, tsVer, `digest.version mismatch on ${source} topic=${topic}`);

    stats.keyedPairsChecked++;
    stats.keyedPairsByTopic[topic] = (stats.keyedPairsByTopic[topic] || 0) + 1;
  }
});

test("3. coverage-ledger.mjs --json produces complete real denominator statistics", () => {
  const ledgerScript = path.join(repoRoot, "pion/client-core/scripts/coverage-ledger.mjs");
  const rawJson = execFileSync(process.execPath, [ledgerScript, "--json"], {
    cwd: repoRoot,
    encoding: "utf8",
    maxBuffer: 16 * 1024 * 1024,
  });
  const ledger = JSON.parse(rawJson);

  // Exact structural & denominator assertions
  assert.equal(ledger.topicsTotal, Object.keys(protocolTs.TOPICS).length);
  assert.equal(ledger.topicsReal + ledger.topicsStaticStub + ledger.topicsMissing, ledger.topicsTotal);
  assert.ok(ledger.topicsReal > 0, "topicsReal should be > 0");
  assert.ok(ledger.topicsStaticStub > 0, "topicsStaticStub should be > 0 (core_runtime static shims)");
  assert.ok(ledger.topicsMissing > 0, "topicsMissing should be > 0");
  assert.ok(Array.isArray(ledger.topicsShadowedByRuntimeStub), "topicsShadowedByRuntimeStub must be an array");
  for (const t of ledger.topics) {
    if (t.shadowedByRuntimeIntercept) {
      assert.equal(t.status, "static-stub", `runtime-shadowed topic ${t.name} must not be classified as real`);
    }
  }
  for (const o of ledger.ops) {
    if (o.shadowedByRuntimeIntercept) {
      assert.equal(o.status, "stub", `runtime-shadowed op ${o.name} must not be classified as real`);
    }
  }
  assert.ok(Array.isArray(ledger.callsShadowedByRuntimeStub), "callsShadowedByRuntimeStub must be an array");
  assert.ok(Array.isArray(ledger.extraPionCallsNotInOpsOrReplays), "extraPionCallsNotInOpsOrReplays must be an array");

  assert.equal(ledger.opsTotal, Object.keys(opsTs.PARAMS).length);
  assert.equal(ledger.opsReal + ledger.opsStub + ledger.opsMissing, ledger.opsTotal);
  assert.ok(ledger.opsMissing > 0, "opsMissing should be > 0");

  assert.equal(ledger.replaysTotal, corpus.traceFiles.length + corpus.tapeFiles.length);
  assert.ok(ledger.replaysTotal >= 80, `replaysTotal should be >= 80, got ${ledger.replaysTotal}`);
  assert.equal(ledger.replayClientMessagesChecked, corpus.clientMessages.length);
  assert.ok(Array.isArray(ledger.missingTopicsTop30) && ledger.missingTopicsTop30.length > 0);
  assert.ok(Array.isArray(ledger.missingCallsTop30) && ledger.missingCallsTop30.length > 0);
  assert.ok(ledger.milestones?.targets?.p80 && ledger.milestones?.targets?.p95 && ledger.milestones?.targets?.p100);

  console.log(
    "Coverage Ledger Summary:",
    JSON.stringify(
      {
        topicsTotal: ledger.topicsTotal,
        topicsReal: ledger.topicsReal,
        topicsStaticStub: ledger.topicsStaticStub,
        topicsMissing: ledger.topicsMissing,
        opsTotal: ledger.opsTotal,
        opsReal: ledger.opsReal,
        opsStub: ledger.opsStub,
        opsMissing: ledger.opsMissing,
        replaysTotal: ledger.replaysTotal,
        replayTracesCount: ledger.replayTracesCount,
        replayTapesCount: ledger.replayTapesCount,
        replayFlowsCount: ledger.replayFlowsCount,
        replayClientMessagesChecked: ledger.replayClientMessagesChecked,
        replayTopicsUnique: ledger.replayTopicsUnique,
        replayTopicsReal: ledger.replayTopicsReal,
        replayTopicsStaticStub: ledger.replayTopicsStaticStub,
        replayTopicsMissing: ledger.replayTopicsMissing,
        replayCallsUnique: ledger.replayCallsUnique,
        replayCallsReal: ledger.replayCallsReal,
        replayCallsStub: ledger.replayCallsStub,
        replayCallsMissing: ledger.replayCallsMissing,
        milestones: {
          currentlyCoveredReplays: ledger.milestones.currentlyCoveredReplays,
          p80Items: ledger.milestones.targets.p80.itemsRequiredCount,
          p95Items: ledger.milestones.targets.p95.itemsRequiredCount,
          p100Items: ledger.milestones.targets.p100.itemsRequiredCount,
        },
      },
      null,
      2,
    ),
  );
});
