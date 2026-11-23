// Real TS vs Pion differential parity test suite (Layer 4):
//   Suite 1: Lock Handover & Moved Workspaces (`lock-handover.ts` + `lock-moved.ts` + `lock-statements.ts` vs `lock_view.pion`)
//   Suite 2: Chat Stage & Viewer Attention Rules (`chat-stage.ts` + `decisions.ts` vs `chats_view.pion`, fixed + 200 seeded random rows)
//   Suite 3: Shared File Ranges & Concurrent Downloads (`station/file-ranges.ts` + `views/downloads.ts` vs `downloads_view.pion`)
//   Suite 4: Multi-Hop `moved` Chat Resolution & `LocalOutbox` Reconciliation (`store/moved.pion` + `sync/local_outbox.pion` + `views/chats_view.pion`)
//
// Directly imports `client/core-ts/src/*.ts` as 100% ground truth. Zero hardcoded expectations.

import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";
import { after, before, test } from "node:test";
import { fileURLToPath } from "node:url";

import { Deferred, Effect, Exit, Fiber } from "../../../client/core-ts/node_modules/effect/dist/index.js";
import { ed25519 } from "../../../client/core-ts/node_modules/@noble/curves/ed25519.js";
import { holdLanguage } from "../../../client/core-ts/src/i18n.ts";
import * as lockTs from "../../../client/core-ts/src/lock.ts";
import * as lockHandoverTs from "../../../client/core-ts/src/lock-handover.ts";
import * as lockMovedTs from "../../../client/core-ts/src/lock-moved.ts";
import * as lockStatementsTs from "../../../client/core-ts/src/lock-statements.ts";
import * as oldestTs from "../../../client/core-ts/src/station/oldest.ts";
import * as movedFromTs from "../../../shared/moved-from.ts";
import * as chatStageTs from "../../../client/core-ts/src/chat-stage.ts";
import * as decisionsTs from "../../../client/core-ts/src/decisions.ts";
import { FileRanges } from "../../../client/core-ts/src/station/file-ranges.ts";
import * as downloadsTs from "../../../client/core-ts/src/views/downloads.ts";
import { Runner } from "../../../client/core-ts/src/runtime.ts";
import * as schemaTs from "../../../client/core-ts/src/db/schema.ts";

holdLanguage();

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, "../../..");
const pioncBin = process.env.PIONC || path.join(os.homedir(), ".pion/bin/pionc");

const toHex = (u8) => Buffer.from(u8).toString("hex");
const fromHex = (h) => new Uint8Array(Buffer.from(h, "hex"));

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
    bool(p = 0.5) {
      return this.next() < p;
    },
    pick(arr) {
      return arr[this.int(0, arr.length - 1)];
    },
  };
}

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
  callRaw(op, args = {}) {
    return new Promise((resolve, reject) => {
      this.queue.push({ resolve, reject });
      this.proc.stdin.write(`${JSON.stringify({ op, args })}\n`);
    });
  }
  async call(op, args = {}) {
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
  suite1LockHandover: 0,
  suite1MovedState: 0,
  suite1Statements: 0,
  suite2Stage: 0,
  suite3Ranges: 0,
  suite3SharedReads: 0,
  suite3TitleOf: 0,
  suite4Moved: 0,
  suite4Outbox: 0,
};

before(() => {
  builtBin = path.join(os.tmpdir(), `pion-client-core-parity-l4-${process.pid}`);
  execFileSync(pioncBin, ["build", "-o", builtBin, "pion/client-core/packages/parity_cli"], {
    cwd: repoRoot,
    stdio: "inherit",
  });
  rpc = new ParityClient(builtBin);
});

after(() => {
  if (rpc) rpc.close();
  if (builtBin && fs.existsSync(builtBin)) fs.unlinkSync(builtBin);
  const total = Object.values(counts).reduce((a, b) => a + b, 0);
  console.log(
    `[parity-l4] total=${total} suite1=(handover:${counts.suite1LockHandover}, movedState:${counts.suite1MovedState}, statements:${counts.suite1Statements}) suite2=${counts.suite2Stage} suite3=(ranges:${counts.suite3Ranges}, sharedReads:${counts.suite3SharedReads}, titleOf:${counts.suite3TitleOf}) suite4=(moved:${counts.suite4Moved}, outbox:${counts.suite4Outbox}) diffs=0`,
  );
});

// ---------------------------------------------------------------------------
// Crypto helpers for signing real lock entries & personal logs
// ---------------------------------------------------------------------------

function makeKeypair(seedByte) {
  const seed = new Uint8Array(32);
  for (let i = 0; i < 32; i++) seed[i] = (seedByte * 37 + i * 13 + 7) & 0xff;
  const pub = ed25519.getPublicKey(seed);
  return { seed, pubHex: toHex(pub), keyId: `ed25519:${toHex(pub)}` };
}

function signLockEntry(kp, unsignedEntry) {
  const h = lockTs.entryHash(unsignedEntry);
  const tag = new TextEncoder().encode("stillfail-lock/1 sig\0");
  const digest = fromHex(h);
  const msg = new Uint8Array(tag.length + digest.length);
  msg.set(tag, 0);
  msg.set(digest, tag.length);
  const sig = ed25519.sign(msg, kp.seed);
  return {
    ...unsignedEntry,
    sig: { key: kp.keyId, alg: "Ed25519", sig: toHex(sig) },
  };
}

function makePersonalGenesis(kp, sub, devId, label, at) {
  return signLockEntry(kp, {
    v: 1,
    ws: `person:${sub}`,
    seq: 0,
    prev: null,
    at,
    kind: "genesis",
    body: {
      sub,
      device: {
        id: devId,
        key: kp.keyId,
        label,
      },
    },
  });
}

function appendPersonalWsStmt(chain, kp, sub, ws, body, at) {
  const rootHash = lockTs.entryHash(chain[0]);
  const last = chain[chain.length - 1];
  const e = signLockEntry(kp, {
    v: 1,
    ws: `person:${sub}`,
    seq: chain.length,
    prev: lockTs.entryHash(last),
    at,
    kind: "ws",
    body: lockStatementsTs.commitOf(ws, rootHash, body),
  });
  return [...chain, e];
}

function normalizeTsInForce(inf) {
  const members = {};
  for (const sub of [...inf.f.members.keys()].sort()) {
    const m = inf.f.members.get(sub);
    members[sub] = {
      role: m.role,
      email: m.email,
      lock: inf.f.persons.get(sub) ?? "",
    };
  }
  const devices = {};
  for (const id of [...inf.f.devices.keys()].sort()) {
    const d = inf.f.devices.get(id);
    const out = { sub: d.sub, kind: d.kind, label: d.label };
    if (typeof d.sign_key === "string") out.sign_key = d.sign_key;
    if (d.by === "chain") out.by = "chain";
    devices[id] = out;
  }
  const stations = [...inf.f.stations.keys()].sort();
  return {
    moved: inf.root !== null,
    movedRoot: inf.root,
    on: inf.said === "chain" ? (inf.f.disabled ? "off" : "on") : inf.said === "waiting" ? "no root" : inf.said,
    safeMode: inf.said === "on" || (inf.said === "chain" && !inf.f.disabled),
    members,
    devices,
    stations,
  };
}

// ===========================================================================
// SUB-SUITE 1: Lock Handover, Moved Workspaces & Statement Planning
// ===========================================================================

test("L4 Suite 1a: lock-handover constants, ableBuild, ableLarge, genesisPerson, movedRoot, mayHandOver", async () => {
  const consts = await rpc.call("lock.handoverConstants");
  assert.deepEqual(consts, {
    HAND_OVER_FROM: lockHandoverTs.HAND_OVER_FROM,
    HAND_OVER_FIRST_SECS: lockHandoverTs.HAND_OVER_FIRST_SECS,
    COUNTED_FROM: oldestTs.COUNTED_FROM,
    MOVED_FROM_BUILD: movedFromTs.MOVED_FROM_BUILD,
    ROOT_OUT_FROM_BUILD: movedFromTs.ROOT_OUT_FROM_BUILD,
    LOGS_BEFORE: movedFromTs.LOGS_BEFORE,
    LOGS_ANY_FROM_BUILD: movedFromTs.LOGS_ANY_FROM_BUILD,
  });
  counts.suite1LockHandover++;

  const builds = [
    -100, -1, 0, 1, 500,
    oldestTs.COUNTED_FROM - 1, oldestTs.COUNTED_FROM, oldestTs.COUNTED_FROM + 1,
    movedFromTs.MOVED_FROM_BUILD - 1, movedFromTs.MOVED_FROM_BUILD, movedFromTs.MOVED_FROM_BUILD + 1,
    movedFromTs.ROOT_OUT_FROM_BUILD - 1, movedFromTs.ROOT_OUT_FROM_BUILD,
    movedFromTs.LOGS_ANY_FROM_BUILD - 1, movedFromTs.LOGS_ANY_FROM_BUILD, movedFromTs.LOGS_ANY_FROM_BUILD + 1,
    99999,
  ];
  for (const b of builds) {
    const ab = await rpc.call("lock.ableBuild", { build: b });
    assert.equal(ab, lockHandoverTs.ableBuild(b), `ableBuild(${b})`);
    const al = await rpc.call("lock.ableLarge", { build: b });
    assert.equal(al, lockHandoverTs.ableLarge(b), `ableLarge(${b})`);
    counts.suite1LockHandover += 2;
  }

  const alice = makeKeypair(11);
  const bob = makeKeypair(12);
  const carol = makeKeypair(13);

  const gAt = 1794600000;
  const genesisMatch = signLockEntry(alice, {
    v: 1,
    ws: "ws-h1",
    seq: 0,
    prev: null,
    at: gAt,
    kind: "genesis",
    body: {
      owner: "fallback-owner",
      origins: ["https://app.still.fail"],
      rp_id: "app.still.fail",
      cloud_keys: [],
      members: [
        { sub: "alice", email: "alice@ex.com", role: "owner" },
        { sub: "bob", email: "bob@ex.com", role: "owner" },
        { sub: "carol", email: "carol@ex.com", role: "admin" },
      ],
      devices: [
        { id: "dev-a", sub: "alice", kind: "app", label: "Mac", sign_key: alice.keyId, own: true },
        { id: "dev-b", sub: "bob", kind: "app", label: "Linux", sign_key: bob.keyId, own: true },
      ],
      stations: [{ key: "st-1", name: "Studio" }],
    },
  });

  const genesisFallback = signLockEntry(carol, {
    v: 1,
    ws: "ws-h2",
    seq: 0,
    prev: null,
    at: gAt,
    kind: "genesis",
    body: {
      owner: "alice",
      members: [{ sub: "alice", email: "alice@ex.com", role: "owner" }],
      devices: [{ id: "dev-a", sub: "alice", kind: "app", label: "Mac", sign_key: alice.keyId, own: true }],
      stations: [],
    },
  });

  const genesisNoOwner = {
    v: 1,
    ws: "ws-h3",
    seq: 0,
    prev: null,
    at: gAt,
    kind: "genesis",
    body: { members: [], devices: [], stations: [] },
    sig: { key: carol.keyId, alg: "Ed25519", sig: "" },
  };

  const nonGenesis = {
    v: 1,
    ws: "ws-h4",
    seq: 0,
    prev: null,
    at: gAt,
    kind: "member",
    body: { sub: "alice", email: "alice@ex.com", role: "owner" },
    sig: { key: alice.keyId, alg: "Ed25519", sig: "" },
  };

  for (const entries of [[], [genesisMatch], [genesisFallback], [genesisNoOwner], [nonGenesis]]) {
    const got = await rpc.call("lock.genesisPerson", { entries });
    assert.equal(got, lockHandoverTs.genesisPerson(entries));
    counts.suite1LockHandover++;
  }

  // movedRoot tests
  const movedEntry = {
    v: 1,
    ws: "ws-h1",
    seq: 1,
    prev: lockTs.entryHash(genesisMatch),
    at: gAt + 100,
    kind: "moved",
    body: { root: "aaaa".repeat(16) },
    sig: { key: alice.keyId, alg: "Ed25519", sig: "" },
  };
  const disableEntry = {
    v: 1,
    ws: "ws-h1",
    seq: 2,
    prev: lockTs.entryHash(movedEntry),
    at: gAt + 200,
    kind: "disable",
    body: {},
    sig: { key: alice.keyId, alg: "Ed25519", sig: "" },
  };
  for (const entries of [[], [genesisMatch], [genesisMatch, movedEntry], [genesisMatch, movedEntry, disableEntry]]) {
    const got = await rpc.call("lock.movedRoot", { entries });
    assert.equal(got, lockMovedTs.movedRoot(entries));
    counts.suite1LockHandover++;
  }

  // mayHandOver full matrix
  const demoteAlice = {
    v: 1,
    ws: "ws-h1",
    seq: 1,
    prev: lockTs.entryHash(genesisMatch),
    at: gAt + 50,
    kind: "member",
    body: { sub: "alice", email: "alice@ex.com", role: "admin" },
    sig: { key: bob.keyId, alg: "Ed25519", sig: "" },
  };
  const removeAlice = {
    v: 1,
    ws: "ws-h1",
    seq: 1,
    prev: lockTs.entryHash(genesisMatch),
    at: gAt + 50,
    kind: "member.remove",
    body: { sub: "alice" },
    sig: { key: bob.keyId, alg: "Ed25519", sig: "" },
  };

  const chainsMatrix = [
    [],
    [genesisMatch],
    [genesisMatch, movedEntry],
    [genesisMatch, demoteAlice],
    [genesisMatch, removeAlice],
    [genesisNoOwner],
  ];
  const froms = [lockHandoverTs.HAND_OVER_FROM, gAt - 100000, gAt + 100000];
  const firstSecs = lockHandoverTs.HAND_OVER_FIRST_SECS;
  for (const entries of chainsMatrix) {
    for (const sub of ["alice", "bob", "carol", "nobody"]) {
      for (const from of froms) {
        const base = Math.max(from, entries[0]?.at ?? 0);
        const nows = [base, base + firstSecs - 1, base + firstSecs, base + firstSecs + 1];
        for (const now of nows) {
          const got = await rpc.call("lock.mayHandOver", { entries, sub, from, now });
          const want = lockHandoverTs.mayHandOver(entries, sub, from, now);
          assert.equal(got, want, `mayHandOver mismatch sub=${sub} from=${from} now=${now}`);
          counts.suite1LockHandover++;
        }
      }
    }
  }
});

test("L4 Suite 1b: moved workspace effective_state (`state4_moved`) & statement planning (`lock-statements.ts`)", async () => {
  const ws = "ws-moved-1";
  const now = 1795442000;
  const alice = makeKeypair(21);
  const bob = makeKeypair(22);
  const carol = makeKeypair(23);
  const dave = makeKeypair(24);

  const devAlice = toHex(new Uint8Array(32).fill(0x11));
  const devBob = toHex(new Uint8Array(32).fill(0x22));
  const devCarol = toHex(new Uint8Array(32).fill(0x33));
  const devDave = toHex(new Uint8Array(32).fill(0x44));
  const stAlpha = toHex(new Uint8Array(32).fill(0xa1));
  const stBeta = toHex(new Uint8Array(32).fill(0xb2));

  // Build real personal logs
  let aliceLog = [makePersonalGenesis(alice, "alice", devAlice, "Alice Mac", now - 1000)];
  let bobLog = [makePersonalGenesis(bob, "bob", devBob, "Bob Mac", now - 900)];
  let carolLog = [makePersonalGenesis(carol, "carol", devCarol, "Carol Mac", now - 800)];
  let daveLog = [makePersonalGenesis(dave, "dave", devDave, "Dave Mac", now - 700)];

  const aliceRoot = lockTs.entryHash(aliceLog[0]);
  const bobRoot = lockTs.entryHash(bobLog[0]);
  const carolRoot = lockTs.entryHash(carolLog[0]);
  const daveRoot = lockTs.entryHash(daveLog[0]);

  // Build real workspace chain: genesis -> bind alice/bob -> moved {root: aliceRoot}
  const wsGenesis = signLockEntry(alice, {
    v: 1,
    ws,
    seq: 0,
    prev: null,
    at: now - 500,
    kind: "genesis",
    body: {
      owner: "alice",
      origins: ["https://app.still.fail"],
      rp_id: "app.still.fail",
      cloud_keys: { keys: [] },
      passkeys: [],
      members: [
        { sub: "alice", email: "alice@ex.com", role: "owner" },
        { sub: "bob", email: "bob@ex.com", role: "admin" },
      ],
      devices: [
        { id: devAlice, sub: "alice", kind: "app", label: "Alice Mac", sign_key: alice.keyId },
        { id: devBob, sub: "bob", kind: "app", label: "Bob Mac", sign_key: bob.keyId },
      ],
      stations: [{ key: stAlpha, name: "Alpha" }],
    },
  });
  const bindAlice = signLockEntry(alice, {
    v: 1,
    ws,
    seq: 1,
    prev: lockTs.entryHash(wsGenesis),
    at: now - 450,
    kind: "person",
    body: { sub: "alice", person: aliceRoot },
  });
  const bindBob = signLockEntry(bob, {
    v: 1,
    ws,
    seq: 2,
    prev: lockTs.entryHash(bindAlice),
    at: now - 440,
    kind: "person",
    body: { sub: "bob", person: bobRoot },
  });
  const wsMoved = signLockEntry(alice, {
    v: 1,
    ws,
    seq: 3,
    prev: lockTs.entryHash(bindBob),
    at: now - 400,
    kind: "moved",
    body: { root: aliceRoot },
  });
  const wsChain = [wsGenesis, bindAlice, bindBob, wsMoved];

  const bodies = [];
  const keptMap = () => lockStatementsTs.byHash(bodies);

  // Helper to compare effective_state full output against TS lockMovedTs.inForce
  async function assertMovedStateParity(label, logsList, bodiesList) {
    const chainsMap = new Map(logsList.map((l) => [lockTs.entryHash(l[0]), l]));
    const tsInf = lockMovedTs.inForce(ws, wsChain, chainsMap, bodiesList, now * 1000);
    const tsNorm = normalizeTsInForce(tsInf);
    const pionEff = await rpc.call("lock.effectiveStateFull", {
      ws,
      chain: wsChain,
      personChains: logsList,
      bodies: bodiesList,
      now,
    });
    assert.deepEqual(
      {
        moved: pionEff.moved,
        movedRoot: pionEff.movedRoot,
        on: pionEff.on,
        safeMode: pionEff.safeMode,
        members: pionEff.members,
        devices: pionEff.devices,
        stations: pionEff.stations,
      },
      tsNorm,
      `effectiveStateFull mismatch at ${label}`,
    );
    counts.suite1MovedState++;
  }

  // Case 1: right after move, no statements yet (carried state)
  await assertMovedStateParity("initial-moved", [aliceLog, bobLog], bodies);

  // Case 2: missing root log -> waiting / no root
  await assertMovedStateParity("missing-root", [bobLog], bodies);

  // Case 3: Bob (admin) admits Carol as member + adds station st-beta
  const bobAddCarol = lockStatementsTs.bodyOf(
    ws,
    { kind: "member", sub: "carol", email: "carol@ex.com", lock: carolRoot, role: "member" },
    bobLog,
    keptMap(),
    "00000000000000000000000000000001",
  );
  bodies.push(bobAddCarol);
  bobLog = appendPersonalWsStmt(bobLog, bob, "bob", ws, bobAddCarol, now - 300);

  const bobAddStation = lockStatementsTs.bodyOf(
    ws,
    { kind: "station", key: stBeta },
    bobLog,
    keptMap(),
    "00000000000000000000000000000002",
  );
  bodies.push(bobAddStation);
  bobLog = appendPersonalWsStmt(bobLog, bob, "bob", ws, bobAddStation, now - 290);

  await assertMovedStateParity("bob-admits-carol-and-station", [aliceLog, bobLog, carolLog], bodies);

  // Case 4: Unauthorized statement by Carol (ordinary member) trying to admit Dave or turn off -> ignored by rules
  const carolBogusAdmit = lockStatementsTs.bodyOf(
    ws,
    { kind: "member", sub: "dave", email: "dave@ex.com", lock: daveRoot, role: "owner" },
    carolLog,
    keptMap(),
    "00000000000000000000000000000003",
  );
  bodies.push(carolBogusAdmit);
  carolLog = appendPersonalWsStmt(carolLog, carol, "carol", ws, carolBogusAdmit, now - 250);

  const carolBogusOff = lockStatementsTs.bodyOf(
    ws,
    { kind: "off" },
    carolLog,
    keptMap(),
    "00000000000000000000000000000004",
  );
  bodies.push(carolBogusOff);
  carolLog = appendPersonalWsStmt(carolLog, carol, "carol", ws, carolBogusOff, now - 240);

  await assertMovedStateParity("carol-unauthorized-ignored", [aliceLog, bobLog, carolLog, daveLog], bodies);

  // Case 5: Statement Planning (`lock-statements.ts` `plan`) — Collateral removal protection!
  // Alice removes Bob, who admitted Carol & st-beta -> plan MUST re-state Carol and st-beta before removing Bob!
  const chainsObj = {
    [aliceRoot]: aliceLog,
    [bobRoot]: bobLog,
    [carolRoot]: carolLog,
    [daveRoot]: daveLog,
  };
  const chainsMap = new Map(Object.entries(chainsObj));
  const planCases = [
    {
      name: "collateral-removal-protection",
      own: { genesis: aliceRoot, sub: "alice", key: alice.keyId },
      meant: [{ kind: "member.remove", sub: "bob" }],
    },
    {
      name: "noop-unauthorized-carol-add-dave",
      own: { genesis: carolRoot, sub: "carol", key: carol.keyId },
      meant: [{ kind: "member", sub: "dave", email: "dave@ex.com", lock: daveRoot, role: "member" }],
    },
    {
      name: "non-root-bob-cannot-disable",
      own: { genesis: bobRoot, sub: "bob", key: bob.keyId },
      meant: [{ kind: "off" }],
    },
    {
      name: "root-alice-can-disable",
      own: { genesis: aliceRoot, sub: "alice", key: alice.keyId },
      meant: [{ kind: "off" }],
    },
  ];
  for (const tc of planCases) {
    const tsPlan = lockStatementsTs.plan(ws, aliceRoot, chainsMap, bodies, tc.own, tc.meant, now, wsChain, false);
    const pionPlan = await rpc.call("lock.planStatements", {
      ws,
      root: aliceRoot,
      chains: chainsObj,
      bodies,
      ownGenesis: tc.own.genesis,
      ownSub: tc.own.sub,
      ownKey: tc.own.key,
      meant: tc.meant,
      now,
      moved: wsChain,
      rootOut: false,
    });
    assert.deepEqual(pionPlan, tsPlan, `planStatements mismatch on ${tc.name}`);
    counts.suite1Statements++;
  }

  // Case 6: Root Alice disables safe mode (`off`), then re-enables (`open`)
  const aliceOff = lockStatementsTs.bodyOf(
    ws,
    { kind: "off" },
    aliceLog,
    keptMap(),
    "00000000000000000000000000000005",
  );
  bodies.push(aliceOff);
  aliceLog = appendPersonalWsStmt(aliceLog, alice, "alice", ws, aliceOff, now - 200);
  await assertMovedStateParity("root-disable-off", [aliceLog, bobLog, carolLog], bodies);

  const aliceOpen = lockStatementsTs.bodyOf(
    ws,
    { kind: "open", origins: ["https://app.still.fail"], rp_id: "app.still.fail", cloud_keys: { keys: [] }, email: "alice@ex.com" },
    aliceLog,
    keptMap(),
    "00000000000000000000000000000006",
  );
  bodies.push(aliceOpen);
  aliceLog = appendPersonalWsStmt(aliceLog, alice, "alice", ws, aliceOpen, now - 150);
  await assertMovedStateParity("root-reenable-open", [aliceLog, bobLog, carolLog], bodies);
});

// ===========================================================================
// SUB-SUITE 2: Chat Stage & Viewer Attention Rules (Fixed + 200 Seeded Random Rows)
// ===========================================================================

function buildRandomChatRow(rng, idx) {
  const people = [
    { id: "u-alice", email: "alice@ex.com", name: "Alice" },
    { id: "u-bob", email: "bob@ex.com", name: "Bob" },
    { id: "u-carol", email: "CAROL@ex.com", name: "Carol" },
  ];
  const row = {
    id: `chat-${idx}`,
    mine: rng.bool(0.6),
    unread: rng.bool(0.45),
    pending: rng.bool(0.1),
    unsent: rng.bool(0.1),
  };
  // Creator variants: object, string email, string id, or omitted
  const creatorMode = rng.int(0, 4);
  if (creatorMode === 0) row.creator = rng.pick(people);
  else if (creatorMode === 1) row.creator = rng.pick(people).email;
  else if (creatorMode === 2) row.creator = rng.pick(people).id;
  else if (creatorMode === 3) row.creator = { id: rng.pick(people).id, email: "" };

  // Opener (led subchat)
  if (rng.bool(0.2)) {
    row.opener = { led: rng.bool(0.7) };
  }

  // Opened led subchats
  if (rng.bool(0.3)) {
    const n = rng.int(1, 3);
    row.opened = [];
    for (let i = 0; i < n; i++) {
      row.opened.push({ led: rng.bool(0.8), active: rng.bool(0.6), asks: rng.bool(0.4) });
    }
  }

  // Pinned & archive review fields
  const pinMode = rng.int(0, 3);
  if (pinMode === 1) row.pinned = true;
  else if (pinMode === 2) row.pinned = 1795440000000;
  else if (pinMode === 3) row.pinned = false;

  if (rng.bool(0.25)) row.archiveReminderDismissed = rng.bool(0.6);
  if (rng.bool(0.35)) {
    row.archiveReviewed = true;
    row.archiveRecommended = rng.bool(0.5);
  }

  // Agents
  const agentCount = rng.int(0, 2);
  row.agents = [];
  for (let i = 0; i < agentCount; i++) {
    const a = {};
    const kind = rng.int(0, 8);
    if (kind === 0) {
      a.process = "running";
    } else if (kind === 1) {
      a.startFailed = true;
      a.pending = rng.int(0, 2);
    } else if (kind === 2) {
      a.pending = rng.int(1, 3);
    } else if (kind === 3) {
      a.lastTurn = { ending: "all_done", endedAt: 1795440000 };
    } else if (kind === 4) {
      a.lastTurn = { ending: "need_help", endedAt: 1795440000, need: "approve?" };
    } else if (kind === 5) {
      a.lastTurn = { ending: "waiting", endedAt: 1795440000, waitWatch: rng.bool(0.6) };
    } else if (kind === 6) {
      a.lastTurn = { endedAt: null, outcome: null };
    } else if (kind === 7) {
      a.lastTurn = { endedAt: 1795440000, outcome: rng.pick(["failed", "aborted", "other"]) };
    }
    if (rng.bool(0.2)) a.waitingAsync = true;
    if (rng.bool(0.25)) {
      a.watch = { names: rng.bool(0.8) ? ["CI watch"] : [] };
    }
    row.agents.push(a);
  }

  // Card / Decision / Need
  const askMode = rng.int(0, 4);
  const assignee = rng.pick(["alice@ex.com", "ALICE@EX.COM", "bob@ex.com", "u-alice", "", undefined]);
  if (askMode === 1) {
    row.card = {
      seq: 10,
      dismissed: rng.bool(0.3),
      card: { type: "options", ...(assignee !== undefined ? { assignee } : {}) },
      message: { text: "Choose one" },
    };
  } else if (askMode === 2) {
    row.decision = {
      seq: 11,
      dismissed: rng.bool(0.3),
      options: [{ label: "Yes" }],
      ...(rng.bool(0.5) ? { card: { type: "text", ...(assignee !== undefined ? { assignee } : {}) } } : {}),
      message: { text: "Legacy decision" },
    };
  } else if (askMode === 3) {
    row.need = {
      seq: 12,
      dismissed: rng.bool(0.3),
      ...(assignee !== undefined ? { decider: assignee } : {}),
      message: { text: "Need input" },
    };
  }

  return row;
}

test("L4 Suite 2: chat-stage.ts & decisions.ts parity (fixed boundaries + 200 seeded random rows)", async () => {
  const me = { id: "u-alice", email: "alice@ex.com" };
  const rng = makeRng(0x4c345332);

  const cases = [
    // Fixed boundary cases
    {
      name: "led-subchat-suppresses-needsViewer-and-archiveRead",
      row: {
        opener: { led: true },
        mine: true,
        unsent: true,
        creator: me,
        agents: [{ lastTurn: { ending: "all_done", endedAt: 100 } }],
        card: { seq: 1, card: { type: "options", assignee: "alice@ex.com" }, message: { text: "pick" } },
      },
      me,
      opts: { unsent: true },
    },
    {
      name: "active-watch-beats-run-but-loses-to-needsViewer",
      row: {
        mine: true,
        creator: me,
        agents: [{ watch: { names: ["PR CI"] }, lastTurn: { ending: "waiting", endedAt: 100, waitWatch: true } }],
      },
      me,
      opts: {},
    },
    {
      name: "failed-dismissed-vs-undismissed",
      row: {
        mine: true,
        creator: me,
        agents: [{ lastTurn: { endedAt: 100, outcome: "failed" } }],
      },
      me,
      opts: { gone: ["fail-1"], failureId: "fail-1" },
    },
    {
      name: "failed-undismissed",
      row: {
        mine: true,
        creator: me,
        agents: [{ lastTurn: { endedAt: 100, outcome: "failed" } }],
      },
      me,
      opts: { gone: ["fail-other"], failureId: "fail-1" },
    },
    {
      name: "ask-for-colleague-is-run",
      row: {
        mine: true,
        creator: me,
        agents: [{ lastTurn: { ending: "all_done", endedAt: 100 } }],
        card: { seq: 5, card: { type: "options", assignee: "bob@ex.com" }, message: { text: "Bob decide" } },
      },
      me,
      opts: {},
    },
    {
      name: "settled-archivable-by-starter",
      row: {
        mine: true,
        unread: false,
        creator: me,
        agents: [{ lastTurn: { ending: "all_done", endedAt: 100 } }],
      },
      me,
      opts: {},
    },
    {
      name: "settled-not-archivable-when-pinned-or-kept-or-other-starter",
      row: {
        mine: true,
        unread: false,
        pinned: 1795440000000,
        creator: { id: "u-bob", email: "bob@ex.com" },
        agents: [{ lastTurn: { ending: "all_done", endedAt: 100 } }],
      },
      me,
      opts: {},
    },
  ];

  // Add 200 seeded random rows
  for (let i = 0; i < 200; i++) {
    const row = buildRandomChatRow(rng, i);
    const useMe = rng.bool(0.9) ? me : null;
    const opts = {};
    if (rng.bool(0.25)) {
      opts.gone = rng.bool(0.5) ? [`f-${i}`] : ["f-other"];
      opts.failureId = `f-${i}`;
    }
    if (rng.bool(0.15)) opts.unsent = rng.bool(0.5);
    cases.push({ name: `rand-${i}`, row, me: useMe, opts });
  }

  for (const tc of cases) {
    const tsOpts = {};
    if (tc.opts.gone) {
      tsOpts.gone = new Set(tc.opts.gone);
      tsOpts.failureOf = () => tc.opts.failureId;
    }
    if (tc.opts.unsent !== undefined) tsOpts.unsent = tc.opts.unsent;

    const cardForDec = tc.row.card?.card ?? tc.row.decision?.card ?? {};
    const expected = {
      led: decisionsTs.led(tc.row),
      isLedSubchat: chatStageTs.isLedSubchat(tc.row),
      hasActiveWatch: chatStageTs.hasActiveWatch(tc.row.agents ?? []),
      startedBy: chatStageTs.startedBy(tc.row, tc.me),
      failedForViewer: chatStageTs.failedForViewer(tc.row, tc.me),
      needsViewer: chatStageTs.needsViewer(tc.row, tc.me, tsOpts),
      hasOpenAskForOthers: chatStageTs.hasOpenAskForOthers(tc.row, tc.me),
      archiveRead: chatStageTs.archiveRead(tc.row, tc.me),
      boardStageOf: chatStageTs.boardStageOf(tc.row, tc.me, tsOpts),
      stageFields: chatStageTs.stageFields(tc.row, tc.me, tsOpts),
      undecidedCount: decisionsTs.undecided(tc.row).length,
      forViewerPresent: decisionsTs.forViewer(tc.row, tc.me) !== null,
      decider: decisionsTs.decider(cardForDec, tc.row.creator),
    };

    const got = await rpc.call("stage.evalAll", {
      row: tc.row,
      me: tc.me,
      ...(tc.opts.gone ? { gone: tc.opts.gone, failureId: tc.opts.failureId } : {}),
      ...(tc.opts.unsent !== undefined ? { unsent: tc.opts.unsent } : {}),
      card: cardForDec,
    });

    assert.deepEqual(got, expected, `stage.evalAll mismatch on ${tc.name}: row=${JSON.stringify(tc.row)}`);
    counts.suite2Stage++;
  }
});

// ===========================================================================
// SUB-SUITE 3: Shared File Ranges & Concurrent Downloads
// ===========================================================================

function refMergeRanges(ranges) {
  const valid = ranges.filter((r) => r.end > r.start).sort((a, b) => a.start - b.start || a.end - b.end);
  if (valid.length <= 1) return valid;
  const out = [{ ...valid[0] }];
  for (let i = 1; i < valid.length; i++) {
    const last = out[out.length - 1];
    if (valid[i].start <= last.end) last.end = Math.max(last.end, valid[i].end);
    else out.push({ ...valid[i] });
  }
  return out;
}

function refMissingRanges(want, covered) {
  if (want.end <= want.start) return [];
  const merged = refMergeRanges(covered);
  const out = [];
  let cur = want.start;
  for (const c of merged) {
    if (c.end <= cur) continue;
    if (c.start >= want.end) break;
    if (c.start > cur) out.push({ start: cur, end: c.start });
    if (c.end > cur) cur = c.end;
    if (cur >= want.end) break;
  }
  if (cur < want.end) out.push({ start: cur, end: want.end });
  return out;
}

test("L4 Suite 3a: DOWNLOAD_PART, 200 seeded merge_ranges/missing_ranges, download_title_of", async () => {
  const consts = await rpc.call("downloads.constants");
  assert.equal(consts.DOWNLOAD_PART, downloadsTs.DOWNLOAD_PART);
  counts.suite3Ranges++;

  const rng = makeRng(0x4c345333);
  for (let i = 0; i < 200; i++) {
    const n = rng.int(0, 10);
    const ranges = [];
    for (let j = 0; j < n; j++) {
      const a = rng.int(-5, 100);
      const b = rng.int(-5, 100);
      ranges.push({ start: a, end: b });
    }
    const pionMerged = await rpc.call("downloads.mergeRanges", { ranges });
    const refMerged = refMergeRanges(ranges);
    assert.deepEqual(pionMerged, refMerged, `mergeRanges mismatch seed=${i}`);

    const want = { start: rng.int(0, 60), end: rng.int(0, 110) };
    const pionMissing = await rpc.call("downloads.missingRanges", { want, covered: ranges });
    const refMissing = refMissingRanges(want, ranges);
    assert.deepEqual(pionMissing, refMissing, `missingRanges mismatch seed=${i}`);
    counts.suite3Ranges += 2;
  }

  // download_title_of parity
  const titleCases = [
    "",
    "a",
    "report.pdf",
    "2026-11-23T12-34-56-abcdef-report.pdf",
    "2026-11-23T12-34-56-012345-中文报告🚀.pdf",
    "2026-11-23T12-34-56-abcdef-",
    "2026-11-23T12-34-56-abcdef-\n",
    "2026-11-23T12-34-56-abcdef-\r",
    "2026-11-23T12-34-56-abcdef-a",
    "2026-11-23T12-34-56-ABCDEF-upper.txt",
    "2026-11-23T12-34-56-abcde-short.txt",
    "2026-11-23 12-34-56-abcdef-space.txt",
    "2026-11-23T12-34-56-abcdeg-nonhex.txt",
    "prefix-2026-11-23T12-34-56-abcdef-mid.txt",
    "2026-11-23T12-34-56-abcdef-2026-11-23T12-34-56-123456-double.txt",
    "2026-11-23T12-34-56-abcdef-.hidden",
    "2026-11-23T12-34-56-abcdef- ",
  ];
  for (const name of titleCases) {
    const got = await rpc.call("downloads.titleOf", { name });
    assert.equal(got, downloadsTs.titleOf(name), `titleOf(${JSON.stringify(name)})`);
    counts.suite3TitleOf++;
  }
});

test("L4 Suite 3b: real TS FileRanges vs Pion SharedFileReads concurrent dual-reader, cancellation & version isolation", async () => {
  // Deterministic 12-byte-scaled file (representing 0..12MB pattern)
  const MB = 1024; // 1KB unit for fast exact byte comparison (0..12KB representing 0..12MB)
  const fileV1 = new Uint8Array(12 * MB);
  const fileV2 = new Uint8Array(12 * MB);
  for (let i = 0; i < fileV1.length; i++) {
    fileV1[i] = (i * 31 + 7) & 0xff;
    fileV2[i] = (i * 17 + 199) & 0xff;
  }

  // Helper to run TS FileRanges with controllable in-flight fetches
  async function runTsScenario(order, cancelReader) {
    const runner = new Runner();
    const fr = new FileRanges(runner);
    const fetches = [];
    const interrupted = [];

    const makeFetch = (buf, mtime) => (at, length, take, said) =>
      Effect.suspend(() => {
        const gate = Deferred.makeUnsafe();
        const rec = { at, end: at + length, length, mtime, gate, take, said, cancelled: false };
        fetches.push(rec);
        return Effect.onInterrupt(
          Effect.gen(function* () {
            const head = { type: "application/octet-stream", total: buf.length, mtime };
            said(head);
            yield* Deferred.await(gate);
            take(buf.subarray(at, at + length));
            return head;
          }),
          () => Effect.sync(() => {
            rec.cancelled = true;
            interrupted.push([at, at + length]);
          }),
        );
      });

    const firstRange = order === "AB" ? [0, 8 * MB] : [4 * MB, 12 * MB];
    const secondRange = order === "AB" ? [4 * MB, 12 * MB] : [0, 8 * MB];

    const f1 = runner.fork(fr.read("file-1@v1", firstRange[0], firstRange[1] - firstRange[0], makeFetch(fileV1, 100)));
    await new Promise((r) => setTimeout(r, 5));
    const f2 = runner.fork(fr.read("file-1@v1", secondRange[0], secondRange[1] - secondRange[0], makeFetch(fileV1, 100)));
    await new Promise((r) => setTimeout(r, 5));

    let firstCancelledAfterLeave = null;
    if (cancelReader === "first") {
      await Effect.runPromise(Fiber.interrupt(f1));
      await new Promise((r) => setTimeout(r, 5));
      firstCancelledAfterLeave = fetches[0].cancelled;
      for (const f of fetches) Deferred.doneUnsafe(f.gate, Exit.succeed(undefined));
      const res2 = await Effect.runPromise(Fiber.await(f2));
      assert.equal(Exit.isSuccess(res2), true);
      return {
        intervals: fetches.map((f) => [f.at, f.end]),
        firstCancelledAfterLeave,
        bytes2Hex: toHex(res2.value.bytes),
      };
    } else if (cancelReader === "both") {
      await Effect.runPromise(Fiber.interrupt(f1));
      await new Promise((r) => setTimeout(r, 5));
      const afterOne = fetches[0].cancelled;
      await Effect.runPromise(Fiber.interrupt(f2));
      await new Promise((r) => setTimeout(r, 5));
      const afterBoth = fetches[0].cancelled;
      return {
        intervals: fetches.map((f) => [f.at, f.end]),
        afterOne,
        afterBoth,
      };
    } else {
      for (const f of fetches) Deferred.doneUnsafe(f.gate, Exit.succeed(undefined));
      const r1 = await Effect.runPromise(Fiber.await(f1));
      const r2 = await Effect.runPromise(Fiber.await(f2));
      assert.equal(Exit.isSuccess(r1), true);
      assert.equal(Exit.isSuccess(r2), true);
      return {
        intervals: fetches.map((f) => [f.at, f.end]),
        bytes1Hex: toHex(r1.value.bytes),
        bytes2Hex: toHex(r2.value.bytes),
      };
    }
  }

  // 1. Order AB (A=[0,8KB), B=[4KB,12KB)) and Order BA (B=[4KB,12KB), A=[0,8KB))
  for (const order of ["AB", "BA"]) {
    const tsOut = await runTsScenario(order, "none");
    const first = order === "AB" ? { reader: "A", start: 0, end: 8 * MB } : { reader: "B", start: 4 * MB, end: 12 * MB };
    const second = order === "AB" ? { reader: "B", start: 4 * MB, end: 12 * MB } : { reader: "A", start: 0, end: 8 * MB };
    const expectedSecondStart = order === "AB" ? 8 * MB : 0;
    const expectedSecondEnd = order === "AB" ? 12 * MB : 4 * MB;

    const pionOut = await rpc.call("downloads.simSharedReads", {
      checkFileKey: "file-1",
      checkVersion: "v1",
      steps: [
        { kind: "join", ...first, fileKey: "file-1", version: "v1" },
        { kind: "join", ...second, fileKey: "file-1", version: "v1" },
        { kind: "deliver", reqId: 1, offset: first.start, hex: toHex(fileV1.subarray(first.start, first.end)) },
        { kind: "complete", reqId: 1 },
        { kind: "deliver", reqId: 2, offset: expectedSecondStart, hex: toHex(fileV1.subarray(expectedSecondStart, expectedSecondEnd)) },
        { kind: "complete", reqId: 2 },
        { kind: "read", fileKey: "file-1", version: "v1", start: first.start, end: first.end },
        { kind: "read", fileKey: "file-1", version: "v1", start: second.start, end: second.end },
      ],
    });
    assert.equal(pionOut.hasDuplicates, false);
    assert.deepEqual(
      pionOut.dispatched.map((d) => [d.start, d.end]),
      tsOut.intervals,
      `dispatched intervals mismatch for order=${order}`,
    );
    assert.equal(pionOut.steps[6].hex, tsOut.bytes1Hex, `reader 1 bytes mismatch order=${order}`);
    assert.equal(pionOut.steps[7].hex, tsOut.bytes2Hex, `reader 2 bytes mismatch order=${order}`);
    counts.suite3SharedReads++;
  }

  // 2. Non-last reader leaves -> shared range stays active; last reader leaves -> cancelled!
  const tsCancelOne = await runTsScenario("AB", "first");
  const pionCancelOne = await rpc.call("downloads.simSharedReads", {
    checkFileKey: "file-1",
    checkVersion: "v1",
    steps: [
      { kind: "join", reader: "A", fileKey: "file-1", version: "v1", start: 0, end: 8 * MB },
      { kind: "join", reader: "B", fileKey: "file-1", version: "v1", start: 4 * MB, end: 12 * MB },
      { kind: "leave", reader: "A" },
      { kind: "isActive", reqId: 1 },
      { kind: "deliver", reqId: 1, offset: 0, hex: toHex(fileV1.subarray(0, 8 * MB)) },
      { kind: "complete", reqId: 1 },
      { kind: "deliver", reqId: 2, offset: 8 * MB, hex: toHex(fileV1.subarray(8 * MB, 12 * MB)) },
      { kind: "complete", reqId: 2 },
      { kind: "read", fileKey: "file-1", version: "v1", start: 4 * MB, end: 12 * MB },
    ],
  });
  assert.equal(!pionCancelOne.steps[3].active, tsCancelOne.firstCancelledAfterLeave);
  assert.equal(pionCancelOne.steps[2].cancelled.length, 0);
  assert.equal(pionCancelOne.steps[8].hex, tsCancelOne.bytes2Hex);
  counts.suite3SharedReads++;

  const tsCancelBoth = await runTsScenario("AB", "both");
  const pionCancelBoth = await rpc.call("downloads.simSharedReads", {
    checkFileKey: "file-1",
    checkVersion: "v1",
    steps: [
      { kind: "join", reader: "A", fileKey: "file-1", version: "v1", start: 0, end: 8 * MB },
      { kind: "join", reader: "B", fileKey: "file-1", version: "v1", start: 4 * MB, end: 12 * MB },
      { kind: "leave", reader: "A" },
      { kind: "isActive", reqId: 1 },
      { kind: "leave", reader: "B" },
      { kind: "isActive", reqId: 1 },
    ],
  });
  assert.equal(!pionCancelBoth.steps[3].active, tsCancelBoth.afterOne);
  assert.equal(!pionCancelBoth.steps[5].active, tsCancelBoth.afterBoth);
  assert.deepEqual(pionCancelBoth.steps[4].cancelled, [1, 2]);
  counts.suite3SharedReads++;

  // 3. Cross-version isolation: v2 MUST NOT reuse v1 bytes
  const pionVer = await rpc.call("downloads.simSharedReads", {
    checkFileKey: "file-1",
    checkVersion: "v2",
    steps: [
      { kind: "join", reader: "A", fileKey: "file-1", version: "v1", start: 0, end: 4 * MB },
      { kind: "deliver", reqId: 1, offset: 0, hex: toHex(fileV1.subarray(0, 4 * MB)) },
      { kind: "complete", reqId: 1 },
      { kind: "join", reader: "B", fileKey: "file-1", version: "v2", start: 0, end: 4 * MB },
      { kind: "deliver", reqId: 2, offset: 0, hex: toHex(fileV2.subarray(0, 4 * MB)) },
      { kind: "complete", reqId: 2 },
      { kind: "read", fileKey: "file-1", version: "v1", start: 0, end: 4 * MB },
      { kind: "read", fileKey: "file-1", version: "v2", start: 0, end: 4 * MB },
    ],
  });
  assert.equal(pionVer.steps[3].newRequests.length, 1);
  assert.equal(pionVer.steps[6].hex, toHex(fileV1.subarray(0, 4 * MB)));
  assert.equal(pionVer.steps[7].hex, toHex(fileV2.subarray(0, 4 * MB)));
  assert.notEqual(pionVer.steps[6].hex, pionVer.steps[7].hex);
  counts.suite3SharedReads++;
});

// ===========================================================================
// SUB-SUITE 4: Multi-Hop `moved` Chat Resolution & `LocalOutbox` Reconciliation
// ===========================================================================

// Reference TS `Data.chatNow` over real `node:sqlite` initialized with `client/core-ts/src/db/schema.ts`
function tsResolveMoved(hops, queries) {
  const db = new DatabaseSync(":memory:");
  for (const m of schemaTs.MIGRATIONS) db.exec(m);
  schemaTs.ensureMoved({
    exec: (s) => db.exec(s),
    all: (s, p = []) => db.prepare(s).all(...p),
    run: (s, p = []) => db.prepare(s).run(...p),
  });
  const putStmt = db.prepare(
    "INSERT OR REPLACE INTO moved (station, session, there_station, thread, there, at, came) VALUES (?, ?, ?, ?, ?, ?, ?)",
  );
  const delStmt = db.prepare("DELETE FROM moved WHERE station = ? AND session = ?");
  for (const h of hops) {
    if (!h.to || h.to.station === h.station) {
      delStmt.run(h.station, h.session);
    } else {
      putStmt.run(
        h.station,
        h.session,
        h.to.station,
        h.to.thread ?? null,
        h.to.there ?? null,
        h.to.at ?? null,
        h.to.came ? 1 : 0,
      );
    }
  }
  const getMoved = db.prepare("SELECT there_station, thread, there, at, came FROM moved WHERE station = ? AND session = ?");
  const byThread = db.prepare("SELECT session FROM moved WHERE station = ? AND thread = ? LIMIT 1");

  const chatNow = (station, q) => {
    const session = q.thread !== undefined ? byThread.get(station, q.thread)?.session : q.session;
    if (session === undefined) return null;
    let at = station;
    let thread = q.thread !== undefined ? q.thread : null;
    const seen = new Set([at]);
    for (;;) {
      const to = getMoved.get(at, session);
      if (to === undefined) break;
      if (seen.has(to.there_station)) return null;
      seen.add(to.there_station);
      at = to.there_station;
      thread = to.there ?? null;
    }
    return at === station ? null : { station: at, session, thread };
  };
  const out = queries.map((q) => chatNow(q.station, q));
  db.close();
  return out;
}

test("L4 Suite 4a: Multi-hop `moved` chat resolution, cycle protection & multi-station deduplication", async () => {
  // 1. Multi-hop A -> B -> C, cycle X -> Y -> X, unmoved Z, and same-session unmoved on two stations
  const hops = [
    { station: "ws1/A", session: "s-chain", to: { station: "ws1/B", thread: 10, there: 20, at: 1000, came: true } },
    { station: "ws1/B", session: "s-chain", to: { station: "ws1/C", thread: 20, there: 30, at: 2000, came: true } },
    { station: "ws1/X", session: "s-cycle", to: { station: "ws1/Y", thread: 1, there: 2, at: 1000, came: true } },
    { station: "ws1/Y", session: "s-cycle", to: { station: "ws1/X", thread: 2, there: 1, at: 2000, came: true } },
  ];
  const chats = [
    { station: "ws1/A", id: "10", thread: 10, session: "s-chain", lastActiveAt: 1000, doc: { id: "10", session: "s-chain", title: "Old A", agents: [] } },
    { station: "ws1/B", id: "20", thread: 20, session: "s-chain", lastActiveAt: 2000, doc: { id: "20", session: "s-chain", title: "Old B", agents: [] } },
    { station: "ws1/C", id: "30", thread: 30, session: "s-chain", lastActiveAt: 3000, doc: { id: "30", session: "s-chain", title: "Current C", agents: [] } },
    // Same session key on two stations with NO move recorded -> must stay 2 separate chats
    { station: "ws1/A", id: "99", thread: 99, session: "s-shared-name", lastActiveAt: 2500, doc: { id: "99", session: "s-shared-name", title: "Chat on A", agents: [] } },
    { station: "ws1/C", id: "99", thread: 99, session: "s-shared-name", lastActiveAt: 2600, doc: { id: "99", session: "s-shared-name", title: "Chat on C", agents: [] } },
  ];
  const queries = [
    { station: "ws1/A", session: "s-chain" },
    { station: "ws1/B", session: "s-chain" },
    { station: "ws1/C", session: "s-chain" },
    { station: "ws1/A", thread: 10 },
    { station: "ws1/B", thread: 20 },
    { station: "ws1/X", session: "s-cycle" },
    { station: "ws1/Y", session: "s-cycle" },
    { station: "ws1/A", session: "s-unmoved" },
    { station: "ws1/A", session: "s-shared-name" },
  ];

  const tsRes = tsResolveMoved(hops, queries);
  const pionOut = await rpc.call("moved.simResolve", {
    hops,
    chats,
    queries,
    stations: ["ws1/A", "ws1/B", "ws1/C"],
  });

  assert.deepEqual(pionOut.resolved, tsRes, "multi-hop moved resolution mismatch vs TS SQLite Data.chatNow");
  counts.suite4Moved += queries.length;

  // Verify multi-station `chats` list deduplication: s-chain appears ONLY on ws1/C; s-shared-name stays on BOTH ws1/A and ws1/C
  const chainRows = pionOut.listed.filter((r) => r.session === "s-chain");
  assert.deepEqual(chainRows, [{ station: "ws1/C", id: "30", session: "s-chain" }]);
  const sharedRows = pionOut.listed.filter((r) => r.session === "s-shared-name").map((r) => r.station).sort();
  assert.deepEqual(sharedRows, ["ws1/A", "ws1/C"]);
  counts.suite4Moved += 2;
});

test("L4 Suite 4b: LocalOutbox optimistic write, exact clientKey SSE reconciliation, 4xx rollback & offline FIFO flush", async () => {
  // 1. Optimistic write + exact clientKey reconciliation (two identical-text messages with distinct clientKeys!)
  const exactRes = await rpc.call("outbox.simRun", {
    station: "ws1/s1",
    replies: [], // 202 pending SSE
    steps: [
      { kind: "online", value: true },
      { kind: "send", thread: 10, clientKey: "ck-1", author: "alice", text: "same text", at: 1000 },
      { kind: "send", thread: 10, clientKey: "ck-2", author: "alice", text: "same text", at: 1001 },
      { kind: "snapshot", thread: 10 },
      // SSE entry with non-matching clientKey must NOT touch either item
      { kind: "sseEntry", thread: 10, n: 50, clientKey: "ck-other" },
      { kind: "snapshot", thread: 10 },
      // SSE entry matching ck-2 removes ONLY ck-2 (never guesses by text and removes ck-1!)
      { kind: "sseEntry", thread: 10, n: 51, clientKey: "ck-2" },
      { kind: "snapshot", thread: 10 },
      // SSE entry matching ck-1 clears outbox completely
      { kind: "sseEntry", thread: 10, n: 52, clientKey: "ck-1" },
      { kind: "snapshot", thread: 10 },
    ],
  });
  assert.equal(exactRes.snapshots[0].pendingCount, 2);
  assert.deepEqual(exactRes.snapshots[0].dbOutbox.map((x) => x.clientKey), ["ck-1", "ck-2"]);
  assert.equal(exactRes.snapshots[1].pendingCount, 2);
  assert.equal(exactRes.snapshots[2].pendingCount, 1);
  assert.deepEqual(exactRes.snapshots[2].dbOutbox.map((x) => x.clientKey), ["ck-1"]);
  assert.equal(exactRes.snapshots[3].pendingCount, 0);
  assert.deepEqual(exactRes.snapshots[3].dbOutbox, []);
  counts.suite4Outbox += 4;

  // 2. Station 4xx rejection -> atomic rollback of outbox + recovery hint
  const rejectRes = await rpc.call("outbox.simRun", {
    station: "ws1/s1",
    replies: [
      {
        clientKey: "ck-bad",
        status: 403,
        body: JSON.stringify({ code: "forbidden", recovery: "Re-authenticate on station." }),
      },
    ],
    steps: [
      { kind: "online", value: true },
      { kind: "send", thread: 10, clientKey: "ck-bad", author: "alice", text: "blocked", at: 2000 },
      { kind: "snapshot", thread: 10 },
    ],
  });
  assert.equal(rejectRes.finalPendingCount, 0);
  assert.deepEqual(rejectRes.snapshots[0].dbOutbox, []);
  const rb = rejectRes.events.find((e) => e.kind === "rolledBack");
  assert.ok(rb, "expected OverlayRolledBack event on 403 rejection");
  assert.equal(rb.clientKey, "ck-bad");
  assert.equal(rb.code, "forbidden");
  assert.equal(rb.recovery, "Re-authenticate on station.");
  counts.suite4Outbox += 2;

  // 3. Offline backlog (3 messages) -> reconnect flush in strict FIFO order & exact reconciliation
  const fifoRes = await rpc.call("outbox.simRun", {
    station: "ws1/s1",
    replies: [
      { clientKey: "m-1", status: 200, body: JSON.stringify({ n: 101, clientKey: "m-1" }) },
      { clientKey: "m-2", status: 200, body: JSON.stringify({ n: 102, clientKey: "m-2" }) },
      { clientKey: "m-3", status: 200, body: JSON.stringify({ n: 103, clientKey: "m-3" }) },
    ],
    steps: [
      { kind: "online", value: false },
      { kind: "send", thread: 20, clientKey: "m-1", author: "alice", text: "first", at: 3001 },
      { kind: "send", thread: 20, clientKey: "m-2", author: "alice", text: "second", at: 3002 },
      { kind: "send", thread: 20, clientKey: "m-3", author: "alice", text: "third", at: 3003 },
      { kind: "snapshot", thread: 20 },
      { kind: "online", value: true },
      { kind: "flush" },
      { kind: "snapshot", thread: 20 },
    ],
  });
  assert.equal(fifoRes.snapshots[0].pendingCount, 3);
  assert.deepEqual(fifoRes.sentOrder, ["m-1", "m-2", "m-3"]);
  assert.equal(fifoRes.finalPendingCount, 0);
  assert.deepEqual(fifoRes.snapshots[1].dbOutbox, []);
  const resolvedOrder = fifoRes.events.filter((e) => e.kind === "resolved").map((e) => [e.clientKey, e.n]);
  assert.deepEqual(resolvedOrder, [["m-1", 101], ["m-2", 102], ["m-3", 103]]);
  counts.suite4Outbox += 3;
});
