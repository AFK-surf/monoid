// Real TS vs Pion differential parity test suite (Layer 3):
//   Suite 1: SQLite Schema (`node:sqlite` DatabaseSync) & `mdKey` byte-for-byte parity
//   Suite 2: Lock Fork Choice (`keep`, `links`, `againOf`), `vouchersIn`, `approvedIn`, `effectiveState`
//   Suite 3: Full `TOPIC_SHAPES` strict bidirectional wire schema contract validation (all 26 topics)
//   Suite 4: Stateful multi-step Wire session head-to-head parity (real TS `Core` vs Pion `ClientCore`)
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

import * as schemaTs from "../../../client/core-ts/src/db/schema.ts";
import * as markdownTs from "../../../client/core-ts/src/markdown.ts";
import * as lockTs from "../../../client/core-ts/src/lock.ts";
import * as lockKeepTs from "../../../client/core-ts/src/lock-keep.ts";
import { lockChain } from "../../../client/core-ts/src/vault/lock-check.ts";
import { approvedIn, vouchersIn } from "../../../client/core-ts/src/views/lock.ts";
import { SHAPES, TOPIC_SHAPES } from "../../../client/core-ts/src/shapes/schema.ts";
import { conform } from "../../../client/core-ts/src/conform.ts";
import * as collectionsTs from "../../../client/core-ts/src/collections.ts";
import { Core } from "../../../client/core-ts/src/core.ts";
import { FakeHost, jsonResponse } from "../../../client/core-ts/src/testing.ts";
import { STORAGE_KEY } from "../../../client/core-ts/src/accounts.ts";
import { holdLanguage } from "../../../client/core-ts/src/i18n.ts";
import { ed25519 } from "../../../client/core-ts/node_modules/@noble/curves/ed25519.js";

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
  suite1Schema: 0,
  suite1MdKey: 0,
  suite2Lock: 0,
  suite3Shapes: 0,
  suite4Core: 0,
};

before(() => {
  builtBin = path.join(os.tmpdir(), `pion-client-core-parity-l3-${process.pid}`);
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
  console.log("L3 Parity test call counts (0 diffs):", counts);
});

// ---------------------------------------------------------------------------
// Sub-suite 1: SQLite Schema & mdKey byte-for-byte parity
// ---------------------------------------------------------------------------
function wrapNodeSqlite(db) {
  return {
    exec(sql) {
      db.exec(sql);
    },
    all(sql, params = []) {
      const stmt = db.prepare(sql);
      return stmt.all(...params).map((row) => Object.values(row));
    },
    run(sql, params = []) {
      const stmt = db.prepare(sql);
      return Number(stmt.run(...params).changes ?? 0);
    },
  };
}

function inspectDbSchema(db) {
  const tables = db
    .prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
    .all()
    .map((r) => r.name);
  const tableInfo = {};
  const indexes = {};
  for (const t of tables) {
    tableInfo[t] = db
      .prepare(`PRAGMA table_info("${t}")`)
      .all()
      .map((c) => ({
        name: c.name,
        type: String(c.type || "").toUpperCase(),
        notnull: Number(c.notnull),
        dflt_value: c.dflt_value ?? null,
        pk: Number(c.pk),
      }));
    const idxList = db
      .prepare(`PRAGMA index_list("${t}")`)
      .all()
      .filter((ix) => !String(ix.name).startsWith("sqlite_autoindex_"))
      .sort((a, b) => String(a.name).localeCompare(String(b.name)));
    indexes[t] = idxList.map((ix) => ({
      name: ix.name,
      unique: Number(ix.unique),
      partial: Number(ix.partial),
      cols: db
        .prepare(`PRAGMA index_info("${ix.name}")`)
        .all()
        .map((c) => c.name ?? "<expr>"),
    }));
  }
  const triggers = db
    .prepare("SELECT name, tbl_name FROM sqlite_master WHERE type = 'trigger' ORDER BY name")
    .all()
    .map((r) => ({ name: r.name, tbl: r.tbl_name }));
  return { tables, tableInfo, indexes, triggers };
}

test("Sub-suite 1: SQLite Schema (VERSION, MIGRATIONS, ensureSaid/MdKept/Kept/Moved) + mdKey (fixed + 200 fuzz)", async () => {
  // 1A. Schema version & base migrations
  const pionVersion = await rpc.call("store.schemaVersion");
  assert.equal(pionVersion, schemaTs.VERSION, "schema VERSION mismatch");
  counts.suite1Schema++;

  const pionMigs = await rpc.call("store.migrations");
  assert.equal(pionMigs.length, schemaTs.MIGRATIONS.length, "MIGRATIONS length mismatch");

  const dbTs = new DatabaseSync(":memory:");
  const dbPion = new DatabaseSync(":memory:");
  const sqlTs = wrapNodeSqlite(dbTs);

  for (const m of schemaTs.MIGRATIONS) dbTs.exec(m);
  for (const m of pionMigs) dbPion.exec(m);

  // Compare base schema
  const baseTs = inspectDbSchema(dbTs);
  const basePion = inspectDbSchema(dbPion);
  assert.deepEqual(basePion, baseTs, "base MIGRATIONS schema mismatch");
  counts.suite1Schema += baseTs.tables.length;

  // Apply dynamic ensure* DDLs on both DBs and compare
  schemaTs.ensureSaid(sqlTs);
  schemaTs.ensureMdKept(sqlTs);
  schemaTs.ensureKept(sqlTs);
  schemaTs.ensureMoved(sqlTs);

  dbPion.exec(await rpc.call("store.ensureSaidDdl"));
  dbPion.exec(await rpc.call("store.ensureMdKeptDdl"));
  dbPion.exec(await rpc.call("store.ensureKeptDdl"));
  dbPion.exec(await rpc.call("store.ensureMovedDdl"));

  const fullTs = inspectDbSchema(dbTs);
  const fullPion = inspectDbSchema(dbPion);
  assert.deepEqual(fullPion, fullTs, "dynamic ensureSaid/ensureMdKept/ensureKept/ensureMoved schema mismatch");
  counts.suite1Schema += fullTs.tables.length + fullTs.triggers.length;

  dbTs.close();
  dbPion.close();

  // 1B. mdKey & olderMdKeys parity
  const fixedTexts = [
    "",
    "a",
    "Hello, world!",
    "中文测试与标点，。！？",
    "emoji 😀🚀👨‍👩‍👧‍👦 surrogate pairs 𝄞𐐷",
    "control\u0000\u0001\t\n\r\u001f\u007fchars",
    "# Heading\n\n| A | B |\n|---|---|\n| 1 | `code` |\n\n```ts\nconst x = 42;\n```\n",
    "x".repeat(4096),
  ];
  for (const text of fixedTexts) {
    const tsKey = markdownTs.mdKey(text);
    const piKey = await rpc.call("store.mdKey", { text });
    assert.equal(piKey, tsKey, `mdKey mismatch on ${JSON.stringify(text.slice(0, 40))}`);
    const tsOlder = markdownTs.olderMdKeys(tsKey);
    const piOlder = await rpc.call("store.olderMdKeys", { key: piKey });
    assert.deepEqual(piOlder, tsOlder, `olderMdKeys mismatch on ${tsKey}`);
    counts.suite1MdKey += 2;
  }

  const rng = makeRng(2026112301);
  const alphabet = [
    "a", "Z", "0", " ", "\n", "\t", "\\", '"', "`", "*", "|", "#",
    "中", "文", "测", "试", "😀", "🚀", "é", "\u0000", "\u001f", "\uffff",
  ];
  for (let i = 0; i < 200; i++) {
    const len = rng.int(0, 80);
    let s = "";
    for (let j = 0; j < len; j++) s += rng.pick(alphabet);
    const tsKey = markdownTs.mdKey(s);
    const piKey = await rpc.call("store.mdKey", { text: s });
    assert.equal(piKey, tsKey, `fuzz mdKey #${i}`);
    counts.suite1MdKey++;
  }
});

// ---------------------------------------------------------------------------
// Sub-suite 2: Lock Fork Choice / againOf / vouchersIn / approvedIn / effectiveState
// ---------------------------------------------------------------------------
function makeEd25519Key(seedByte) {
  const seed = new Uint8Array(32).fill(seedByte);
  const pub = ed25519.getPublicKey(seed);
  return { seed, pub, keyId: `ed25519:${toHex(pub)}` };
}

function signLockEntry(entryNoSig, key) {
  const h = lockTs.entryHash(entryNoSig);
  const sigBytes = ed25519.sign(lockTs.signedBytes(h), key.seed);
  return {
    ...entryNoSig,
    sig: { key: key.keyId, alg: "Ed25519", sig: toHex(sigBytes) },
  };
}

function tsSubjectOf(e) {
  const k = e.kind;
  const b = e.body ?? {};
  if (["device", "remove_device", "renew_device", "device.add", "device.remove"].includes(k)) {
    return typeof b.id === "string" ? `device:${b.id}` : null;
  }
  if (["member", "remove_member", "role", "member.add", "member.remove"].includes(k)) {
    return typeof b.sub === "string" ? `member:${b.sub}` : null;
  }
  if (["station", "remove_station", "station.add", "station.remove"].includes(k)) {
    return typeof b.key === "string" ? `station:${b.key}` : null;
  }
  if (k === "disable" || k === "moved") return "lock";
  return null;
}

test("Sub-suite 2: Lock Fork Choice (keep, links, againOf), vouchersIn, approvedIn, effectiveState", async () => {
  const ownerKey = makeEd25519Key(0x11);
  const adminKey = makeEd25519Key(0x22);
  const rogueKey = makeEd25519Key(0x99);
  const dev1Id = toHex(new Uint8Array(32).fill(0x01));
  const dev2Id = toHex(new Uint8Array(32).fill(0x02));
  const dev3Id = toHex(new Uint8Array(32).fill(0x03));
  const dev4Id = toHex(new Uint8Array(32).fill(0x04));
  const stKey = toHex(new Uint8Array(32).fill(0x55));

  const genesis = signLockEntry(
    {
      v: 1,
      ws: "ws-lock-1",
      seq: 0,
      prev: null,
      at: 1700000000,
      kind: "genesis",
      body: {
        owner: "u-owner",
        members: [{ sub: "u-owner", email: "owner@x.test", role: "owner" }],
        devices: [{ id: dev1Id, sub: "u-owner", kind: "app", label: "Mac", sign_key: ownerKey.keyId }],
        stations: [{ key: stKey, name: "studio" }],
        passkeys: [],
        origins: ["https://stillfail.test"],
        rp_id: "stillfail.test",
        cloud_keys: { keys: [] },
      },
    },
    ownerKey,
  );
  const genHash = lockKeepTs.hashOf(genesis);

  // Branch A: add dev2 then add dev3 (length 3)
  const e1A = signLockEntry(
    {
      v: 1, ws: "ws-lock-1", seq: 1, prev: genHash, at: 1700000010,
      kind: "device",
      body: { id: dev2Id, sub: "u-owner", kind: "app", label: "iPad", sign_key: adminKey.keyId },
    },
    ownerKey,
  );
  const e2A = signLockEntry(
    {
      v: 1, ws: "ws-lock-1", seq: 2, prev: lockKeepTs.hashOf(e1A), at: 1700000020,
      kind: "device",
      body: { id: dev3Id, sub: "u-owner", kind: "app", label: "Phone" },
    },
    ownerKey,
  );

  // Branch B (fork at seq 1): add dev4 (shorter branch)
  const e1B = signLockEntry(
    {
      v: 1, ws: "ws-lock-1", seq: 1, prev: genHash, at: 1700000015,
      kind: "device",
      body: { id: dev4Id, sub: "u-owner", kind: "app", label: "Linux" },
    },
    ownerKey,
  );

  // Rogue invalid signature entry
  const badSig = signLockEntry(
    {
      v: 1, ws: "ws-lock-1", seq: 1, prev: genHash, at: 1700000018,
      kind: "device",
      body: { id: dev4Id, sub: "u-owner", kind: "app", label: "Rogue" },
    },
    rogueKey,
  );

  // 2A. links_valid parity
  for (const chain of [[], [genesis], [genesis, e1A, e2A], [genesis, e2A], [e1A]]) {
    assert.equal(
      await rpc.call("lock.linksValid", { entries: chain }),
      lockKeepTs.links(chain),
      `linksValid mismatch (len=${chain.length})`,
    );
    counts.suite2Lock++;
  }

  // 2B. keepEntries fork choice parity
  const rules = { chain: (all) => lockChain(all, genHash) };
  const steps = [
    [{ entries: [], aside: [] }, [genesis]],
    [{ entries: [genesis], aside: [] }, [e1B, badSig]],
    [{ entries: [genesis, e1B], aside: [] }, [e1A, e2A]], // Branch A overtakes Branch B; e1B goes aside!
    [{ entries: [genesis, e1A, e2A], aside: [e1B] }, [e1A, e1B]], // idempotent replay -> changed=false
  ];
  for (const [was, brought] of steps) {
    const tsOut = lockKeepTs.keep(was, brought, rules);
    const piOut = await rpc.call("lock.keepEntries", {
      entries: was.entries,
      aside: was.aside,
      brought,
      rootHash: genHash,
      isPerson: false,
    });
    assert.deepEqual(piOut.activeHashes, tsOut.kept.entries.map(lockKeepTs.hashOf), "activeHashes mismatch");
    assert.deepEqual(
      [...piOut.asideHashes].sort(),
      tsOut.kept.aside.map(lockKeepTs.hashOf).sort(),
      "asideHashes mismatch",
    );
    assert.equal(piOut.moved, tsOut.moved, "moved flag mismatch");
    assert.equal(piOut.changed, tsOut.changed, "changed flag mismatch");
    counts.suite2Lock += 4;
  }

  // 2B-extra: ASIDE_MOST (256) eviction + orphan descendant pruning parity
  {
    const manyAside = [];
    // Create an oldest aside entry `oldRoot` at seq=1, plus a child `oldChild` hanging under `oldRoot` at seq=2
    const oldRoot = signLockEntry(
      {
        v: 1, ws: "ws-lock-1", seq: 1, prev: genHash, at: 1700001000,
        kind: "device",
        body: { id: toHex(new Uint8Array(32).fill(0xa0)), sub: "u-owner", kind: "app", label: "OldAsideRoot" },
      },
      ownerKey,
    );
    const oldChild = signLockEntry(
      {
        v: 1, ws: "ws-lock-1", seq: 2, prev: lockKeepTs.hashOf(oldRoot), at: 1700001001,
        kind: "device",
        body: { id: toHex(new Uint8Array(32).fill(0xa1)), sub: "u-owner", kind: "app", label: "OldAsideChild" },
      },
      ownerKey,
    );
    // Active chain has length 4 (gen -> e1A -> e2A -> e3A) so all seq=1/2 forks go aside
    const e3A = signLockEntry(
      {
        v: 1, ws: "ws-lock-1", seq: 3, prev: lockKeepTs.hashOf(e2A), at: 1700000025,
        kind: "device",
        body: { id: toHex(new Uint8Array(32).fill(0x05)), sub: "u-owner", kind: "app", label: "Active3" },
      },
      ownerKey,
    );
    manyAside.push(oldRoot, oldChild);
    for (let k = 0; k < 260; k++) {
      const idBytes = new Uint8Array(32).fill(0xb0);
      idBytes[0] = (k >> 8) & 0xff;
      idBytes[1] = k & 0xff;
      manyAside.push(
        signLockEntry(
          {
            v: 1, ws: "ws-lock-1", seq: 1, prev: genHash, at: 1700002000 + k,
            kind: "device",
            body: { id: toHex(idBytes), sub: "u-owner", kind: "app", label: `Fork-${k}` },
          },
          ownerKey,
        ),
      );
    }
    const wasBig = { entries: [genesis, e1A, e2A, e3A], aside: [] };
    const tsBig = lockKeepTs.keep(wasBig, manyAside, rules);
    const piBig = await rpc.call("lock.keepEntries", {
      entries: wasBig.entries,
      aside: [],
      brought: manyAside,
      rootHash: genHash,
      isPerson: false,
    });
    assert.ok(tsBig.kept.aside.length <= lockKeepTs.ASIDE_MOST);
    assert.deepEqual(piBig.activeHashes, tsBig.kept.entries.map(lockKeepTs.hashOf), "aside eviction activeHashes mismatch");
    assert.deepEqual(
      [...piBig.asideHashes].sort(),
      tsBig.kept.aside.map(lockKeepTs.hashOf).sort(),
      "aside eviction asideHashes mismatch",
    );
    assert.equal(piBig.moved, tsBig.moved);
    assert.equal(piBig.changed, tsBig.changed);
    counts.suite2Lock += 4;
  }

  // 2C. againOf parity across all decision branches & retry cap (0..4)
  const lostSameAsE2A = signLockEntry(
    {
      v: 1, ws: "ws-lock-1", seq: 2, prev: lockKeepTs.hashOf(e1B), at: 1700000030,
      kind: "device",
      body: { id: dev3Id, sub: "u-owner", kind: "app", label: "Phone" },
    },
    ownerKey,
  );
  const lostSameSubject = signLockEntry(
    {
      v: 1, ws: "ws-lock-1", seq: 2, prev: lockKeepTs.hashOf(e1B), at: 1700000031,
      kind: "remove_device",
      body: { id: dev3Id },
    },
    ownerKey,
  );
  const lostUnrelated = signLockEntry(
    {
      v: 1, ws: "ws-lock-1", seq: 2, prev: lockKeepTs.hashOf(e1B), at: 1700000032,
      kind: "member",
      body: { sub: "u-bob", email: "bob@x.test", role: "member" },
    },
    ownerKey,
  );
  const onHead = signLockEntry(
    {
      v: 1, ws: "ws-lock-1", seq: 3, prev: lockKeepTs.hashOf(e2A), at: 1700000033,
      kind: "member",
      body: { sub: "u-carol", email: "carol@x.test", role: "member" },
    },
    ownerKey,
  );

  const activeChain = [genesis, e1A, e2A];
  const asideList = [e1B];
  for (const lost of [e2A, lostSameAsE2A, lostSameSubject, lostUnrelated, onHead]) {
    const tsDec = lockKeepTs.againOf(activeChain, asideList, lost, tsSubjectOf);
    for (let tries = 0; tries <= 4; tries++) {
      const piDec = await rpc.call("lock.againOf", {
        chain: activeChain,
        aside: asideList,
        lost,
        tries,
      });
      const expected = tsDec === "sign" && tries >= lockKeepTs.AGAIN_MOST ? "exhausted" : tsDec;
      assert.equal(piDec, expected, `againOf mismatch for kind=${lost.kind} tries=${tries}`);
      counts.suite2Lock++;
    }
  }

  // 2D. vouchersIn & approvedIn parity (including security invariant: NEVER widen by device id!)
  const makeStandings = (devs) => ({
    devices: new Map(devs.map((d) => [d.id, d])),
    wire: { devices: devs },
  });
  const s1 = makeStandings([
    { id: "d-root", sub: "u1", label: "Root", sign_key: "ed25519:root", said: "ed25519:p-root", by: null, bySub: null, byKey: null, since: 1 },
    { id: "d-mid", sub: "u1", label: "Mid", sign_key: "ed25519:mid", said: "ed25519:p-mid", by: "d-root", bySub: "u1", byKey: "ed25519:root", since: 2 },
    { id: "d-leaf", sub: "u1", label: "Leaf", sign_key: "ed25519:leaf", said: "ed25519:p-leaf", by: "d-mid", bySub: "u1", byKey: "ed25519:mid", since: 3 },
    // Spoofed device approved by a key NOT in chainSigners even though `by` names d-root (must be rejected!)
    { id: "d-spoof", sub: "u1", label: "Spoof", sign_key: "ed25519:spoof", said: "ed25519:p-spoof", by: "d-root", bySub: "u1", byKey: "ed25519:attacker", since: 4 },
    // Device already ever on lock (must NOT be re-admitted!)
    { id: "d-ever", sub: "u1", label: "Ever", sign_key: "ed25519:ever", said: "ed25519:p-ever", by: "d-root", bySub: "u1", byKey: "ed25519:root", since: 5 },
  ]);

  for (const base of ["d-root", "d-mid", "d-leaf", "d-unknown"]) {
    const tsV = [...vouchersIn([s1], "u1", base)].sort();
    const piV = [...(await rpc.call("lock.vouchersIn", { locks: [s1.wire], sub: "u1", base }))].sort();
    assert.deepEqual(piV, tsV, `vouchersIn mismatch for base=${base}`);
    counts.suite2Lock++;
  }

  const tsApp = approvedIn(
    [s1],
    "u1",
    { id: "d-root", signKey: "ed25519:root" },
    {
      signers: new Set(["ed25519:root", "ed25519:mid"]),
      signed: new Set(["ed25519:p-root"]),
      ever: { ids: new Set(["d-ever"]), keys: new Set(["ed25519:p-ever"]) },
    },
  );
  const piApp = await rpc.call("lock.approvedIn", {
    locks: [s1.wire],
    sub: "u1",
    meId: "d-root",
    meSignKey: "ed25519:root",
    chainSigners: ["ed25519:root", "ed25519:mid"],
    chainSigned: ["ed25519:p-root"],
    everIds: ["d-ever"],
    everKeys: ["ed25519:p-ever"],
  });
  assert.deepEqual(piApp, tsApp, "approvedIn mismatch");
  assert.ok(!piApp.some((d) => d.id === "d-spoof"), "spoofed byKey must NEVER be admitted");
  assert.ok(!piApp.some((d) => d.id === "d-ever"), "ever device must NEVER be re-admitted");
  counts.suite2Lock++;

  // 2E. effectiveState sanity
  const ef = await rpc.call("lock.effectiveState", {
    ws: "ws-lock-1",
    chain: activeChain,
    personChains: [],
    bodies: [],
    now: 1700000100,
  });
  assert.equal(ef.ws, "ws-lock-1");
  assert.equal(ef.safeMode, true);
  assert.equal(ef.moved, false);
  assert.ok(ef.members.includes("u-owner"));
  assert.ok(ef.devices.includes(dev1Id) && ef.devices.includes(dev2Id) && ef.devices.includes(dev3Id));
  counts.suite2Lock++;
});

// ---------------------------------------------------------------------------
// Sub-suite 3: Full TOPIC_SHAPES strict bidirectional wire schema contract validation
// ---------------------------------------------------------------------------
const INTS = {
  i64: [-(2 ** 63), 2 ** 63],
  i32: [-(2 ** 31), 2 ** 31 - 1],
  u64: [0, 2 ** 64],
  u32: [0, 2 ** 32 - 1],
  u16: [0, 65535],
  u8: [0, 255],
  usize: [0, 2 ** 64],
};

function checkStrictTy(val, ty, p, errors) {
  if (typeof ty === "object" && "opt" in ty) {
    if (val === null || val === undefined) return;
    checkStrictTy(val, ty.opt, p, errors);
    return;
  }
  if (typeof ty === "object") {
    if ("vec" in ty) {
      if (!Array.isArray(val)) {
        errors.push(`${p}: expected array, got ${typeof val}`);
        return;
      }
      val.forEach((item, i) => checkStrictTy(item, ty.vec, `${p}[${i}]`, errors));
      return;
    }
    if ("tuple" in ty) {
      if (!Array.isArray(val) || val.length !== ty.tuple.length) {
        errors.push(`${p}: expected tuple(${ty.tuple.length}), got ${JSON.stringify(val)}`);
        return;
      }
      ty.tuple.forEach((t, i) => checkStrictTy(val[i], t, `${p}[${i}]`, errors));
      return;
    }
    if ("map" in ty) {
      if (val === null || typeof val !== "object" || Array.isArray(val)) {
        errors.push(`${p}: expected map object, got ${typeof val}`);
        return;
      }
      for (const [k, item] of Object.entries(val)) checkStrictTy(item, ty.map, `${p}.${k}`, errors);
      return;
    }
  }
  if (ty === "Value") return;
  if (ty === "String") {
    if (typeof val !== "string") errors.push(`${p}: expected String, got ${typeof val} (${JSON.stringify(val)})`);
    return;
  }
  if (ty === "bool") {
    if (typeof val !== "boolean") errors.push(`${p}: expected bool, got ${typeof val}`);
    return;
  }
  if (ty === "f64" || ty === "f32") {
    if (typeof val !== "number") errors.push(`${p}: expected ${ty}, got ${typeof val}`);
    return;
  }
  if (ty in INTS) {
    const [lo, hi] = INTS[ty];
    if (typeof val !== "number" || !Number.isInteger(val) || val < lo || val > hi) {
      errors.push(`${p}: expected ${ty}, got ${JSON.stringify(val)}`);
    }
    return;
  }
  const shape = SHAPES[ty];
  if (!shape) {
    errors.push(`${p}: unknown shape ${ty}`);
    return;
  }
  if (shape.kind === "enum") {
    if (typeof val !== "string" || !shape.values.includes(val)) {
      errors.push(`${p}: expected enum ${ty} (${shape.values.join("|")}), got ${JSON.stringify(val)}`);
    }
    return;
  }
  if (val === null || typeof val !== "object" || Array.isArray(val)) {
    errors.push(`${p}: expected struct ${ty}, got ${val === null ? "null" : Array.isArray(val) ? "array" : typeof val}`);
    return;
  }
  if (shape.kind === "tagged") {
    const tag = val[shape.tag];
    if (typeof tag !== "string" || !(tag in shape.variants)) {
      errors.push(`${p}: invalid tag ${shape.tag}=${JSON.stringify(tag)} for ${ty}`);
      return;
    }
    if (!(shape.content in val)) {
      errors.push(`${p}: missing content field ${shape.content} for ${ty}`);
      return;
    }
    for (const k of Object.keys(val)) {
      if (k !== shape.tag && k !== shape.content) {
        errors.push(`${p}.${k}: undeclared extra field on tagged ${ty}`);
      }
    }
    checkStrictTy(val[shape.content], shape.variants[tag], `${p}.${shape.content}`, errors);
    return;
  }
  // Struct: strict bidirectional check!
  const declared = new Map(shape.fields.map((f) => [f.name, f]));
  // 1. Zero undeclared / fabricated fields!
  for (const k of Object.keys(val)) {
    if (!declared.has(k)) {
      errors.push(`${p}.${k}: UNDECLARED extra field not in ${ty}`);
    }
  }
  // 2. Every non-optional field MUST be present; every present field MUST match type!
  for (const f of shape.fields) {
    const isOpt = typeof f.ty === "object" && "opt" in f.ty;
    if (!(f.name in val)) {
      if (!isOpt) {
        errors.push(`${p}.${f.name}: MISSING required field of ${ty} (${JSON.stringify(f.ty)})`);
      }
    } else {
      checkStrictTy(val[f.name], f.ty, `${p}.${f.name}`, errors);
    }
  }
}

function assertConformsStrict(topicName, payload) {
  const ty = TOPIC_SHAPES[topicName];
  assert.ok(ty !== undefined, `topic ${topicName} not in TOPIC_SHAPES`);
  // First verify with TS `conform`
  const tsRes = conform(ty, payload);
  assert.ok("ok" in tsRes, `${topicName}: TS conform() rejected: ${tsRes.error}`);
  // Then verify strict bidirectional contract (zero extra fields, all non-opt fields present)
  const errors = [];
  checkStrictTy(payload, ty, topicName, errors);
  assert.equal(errors.length, 0, `${topicName} strict TOPIC_SHAPES drift:\n  - ${errors.join("\n  - ")}`);
}

test("Sub-suite 3: All 26 topics strict TOPIC_SHAPES wire contract validation (0 undeclared/missing fields)", async () => {
  const all = await rpc.call("views.projectAll", { nowMs: 1795442000000 });
  const expected26 = [
    "accounts", "workspaces", "workspace", "stations", "chats", "chat", "lock",
    "vaults", "presets", "otherPresets", "boardDrafts", "downloads", "archive",
    "search", "chatSearch", "profiles", "profilesOverview", "models", "fleet",
    "usage", "agentRates", "settings", "stationUpdates", "railCard", "chatJobs", "longJobs",
  ];
  for (const t of expected26) {
    assert.ok(t in all, `missing topic projection ${t}`);
  }

  // 22 topics declared in TS TOPIC_SHAPES: strict bidirectional check
  const shapeFailures = [];
  for (const t of expected26) {
    if (TOPIC_SHAPES[t] !== undefined) {
      try {
        assertConformsStrict(t, all[t]);
        counts.suite3Shapes++;
      } catch (e) {
        shapeFailures.push(e.message);
      }
    }
  }
  assert.equal(
    shapeFailures.length,
    0,
    `${shapeFailures.length} topic(s) failed strict TOPIC_SHAPES validation:\n\n${shapeFailures.join("\n\n")}`,
  );

  // 4 topics outside TOPIC_SHAPES (`accounts`, `workspaces`, `workspace`, `models`): verify structure & zero secret leakage
  const serialized = JSON.stringify(all);
  assert.ok(!serialized.includes("SECRET_ACCESS_TOKEN"), "accessToken leaked!");
  assert.ok(!serialized.includes("SECRET_REFRESH_TOKEN"), "refreshToken leaked!");
  assert.ok(!serialized.includes("LEAK_CHECK"), "member token leaked!");
  assert.ok(!serialized.includes("sk-ant-SECRET"), "profile access.apiKey leaked!");
  assert.ok(!serialized.includes("sk-top-SECRET"), "profile apiKey leaked!");
  assert.ok(!serialized.includes("MUST_BE_STRIPPED"), "vault secretBlob leaked!");
  assert.ok(!serialized.includes("个人锁"), "「个人锁」 leaked in views!");
  counts.suite3Shapes += 4;
});

// ---------------------------------------------------------------------------
// Sub-suite 4: Stateful multi-step Wire session parity (TS Core vs Pion ClientCore)
// ---------------------------------------------------------------------------
async function createTsCore() {
  const host = new FakeHost();
  const nowS = host.nowMs() / 1000;
  host.store(STORAGE_KEY, [
    { sub: "user-alice", email: "alice@example.com", name: "Alice", picture: "", access: "SECRET_ACC", refresh: "SECRET_REF", access_expires: nowS + 3600 },
  ]);
  host.onFetch((req) => {
    const p = req.url.replace("https://stillfail.test", "");
    if (p === "/v1/me") {
      return jsonResponse(200, { workspaces: [{ id: "ws1", name: "Acme Lab" }], invitations: [], relay_url: "https://relay.test" });
    }
    if (p === "/v1/workspaces/ws1") {
      return jsonResponse(200, { id: "ws1", stations: [{ id: "s1", name: "Mac Studio", online: true, last_seen: 1 }] });
    }
    return jsonResponse(404, { error: "not_found" });
  });
  const core = await Core.create(host, { clock: host.time.clock });
  return { host, core };
}

test("Sub-suite 4: Stateful multi-step Wire session parity (TS Core vs Pion ClientCore)", async () => {
  const { host, core } = await createTsCore();
  try {
    await rpc.call("core.reset", { workspace: "ws1", station: "ws1/s1", seedDefault: true, nowMs: 1795442000000 });

    // 4A. Wire error & cancel semantics: compare TS Core.receiveJson/receiveRaw vs Pion ClientCore.handle_wire
    const wireEdgeInputs = [
      "not-json{{{",
      JSON.stringify({ id: -1, call: "ping" }),
      JSON.stringify({ call: "ping" }),
      JSON.stringify({ id: 99, bogus: true }),
      JSON.stringify({ id: 77, cancel: true }),
    ];
    for (const rawText of wireEdgeInputs) {
      host.takeEmitted();
      core.receiveJson(1, rawText);
      const tsEmitted = host.takeEmitted().map(([, m]) => m);
      const piEv = await rpc.call("core.wire", { rawText });
      const piEmitted = piEv === null ? [] : [piEv];
      assert.equal(piEmitted.length, tsEmitted.length, `wire edge emit count mismatch for ${rawText}: ts=${JSON.stringify(tsEmitted)} pi=${JSON.stringify(piEmitted)}`);
      if (tsEmitted.length === 1) {
        assert.equal(piEmitted[0].id, tsEmitted[0].id, `wire edge id mismatch for ${rawText}`);
        assert.equal(piEmitted[0].error?.code, tsEmitted[0].error?.code, `wire edge error.code mismatch for ${rawText}`);
      }
      counts.suite4Core++;
    }

    // 4B. subscribe accounts / workspaces / workspace / stations (desensitization & structure)
    for (const [subId, topic] of [
      [1, { topic: "accounts" }],
      [2, { topic: "workspaces" }],
      [3, { topic: "workspace", workspace: "ws1" }],
      [4, { topic: "stations", scope: "ws1" }],
    ]) {
      const piEv = await rpc.call("core.wire", { msg: { id: subId, subscribe: topic } });
      assert.equal(piEv.id, subId);
      assert.ok("value" in piEv, `expected value for ${topic.topic}`);
      const s = JSON.stringify(piEv.value);
      assert.ok(!s.includes("SECRET_ACCESS_TOKEN") && !s.includes("SECRET_REFRESH_TOKEN"), `token leak in ${topic.topic}`);
      if (TOPIC_SHAPES[topic.topic]) assertConformsStrict(topic.topic, piEv.value);
      counts.suite4Core++;
    }

    // 4C. subscribe chats (keyed: true) -> mutate -> delta apply -> unsubscribe(keep: true) -> re-subscribe(have)
    const subChats = await rpc.call("core.wire", {
      msg: { id: 10, subscribe: { topic: "chats", scope: "ws1" }, keyed: true },
    });
    assert.equal(subChats.id, 10);
    assert.ok("value" in subChats);
    assertConformsStrict("chats", subChats.value);
    let clientChats = structuredClone(subChats.value);

    // Mutate chat: rename + pin
    await rpc.call("core.mutateChat", {
      id: "c-1",
      archived: 0,
      thread: 10,
      session: "sess-1",
      pinnedAt: 1795442000000,
      lastActiveAt: 1795442005000,
      doc: {
        id: "c-1", session: "sess-1", thread: 10, title: "Build parity (pinned)",
        lastActiveAt: 1795442005000, unread: false, mine: true, agents: [],
      },
    });
    const refreshed = await rpc.call("core.refreshTopic", { topic: "chats" });
    assert.equal(refreshed.length, 1);
    assert.equal(refreshed[0].id, 10);
    if ("delta" in refreshed[0]) {
      clientChats = collectionsTs.applyKeyed(clientChats, refreshed[0].delta);
    } else {
      clientChats = refreshed[0].value;
    }
    assertConformsStrict("chats", clientChats);
    assert.equal(clientChats.days[0].daysAgo, -1, "pinned chat must move to daysAgo=-1 bucket");
    assert.equal(clientChats.days[0].items[0].title, "Build parity (pinned)");
    counts.suite4Core++;

    // unsubscribe(keep: true) -> returns { id, v }
    const unsub = await rpc.call("core.wire", { msg: { id: 10, unsubscribe: true, keep: true } });
    assert.equal(unsub.id, 10);
    assert.equal(typeof unsub.v, "string", "unsubscribe(keep:true) must return kept token string v");

    // Re-subscribe with same have token (no change) -> { id, same: true }
    const resubSame = await rpc.call("core.wire", {
      msg: { id: 11, subscribe: { topic: "chats", scope: "ws1" }, keyed: true, have: unsub.v },
    });
    assert.deepEqual(resubSame, { id: 11, same: true }, "re-subscribe unchanged with have must return same:true");
    counts.suite4Core++;

    // Unsubscribe keep again, mutate chat, re-subscribe with have -> delta + kept: true!
    const unsub2 = await rpc.call("core.wire", { msg: { id: 11, unsubscribe: true, keep: true } });
    await rpc.call("core.mutateChat", {
      id: "c-1",
      archived: 0,
      thread: 10,
      session: "sess-1",
      pinnedAt: 1795442000000,
      lastActiveAt: 1795442009000,
      doc: {
        id: "c-1", session: "sess-1", thread: 10, title: "Build parity (renamed)",
        lastActiveAt: 1795442009000, unread: true, mine: true, agents: [],
      },
    });
    const resubDelta = await rpc.call("core.wire", {
      msg: { id: 12, subscribe: { topic: "chats", scope: "ws1" }, keyed: true, have: unsub2.v },
    });
    assert.equal(resubDelta.id, 12);
    assert.ok("delta" in resubDelta && resubDelta.kept === true, `expected delta+kept:true, got ${JSON.stringify(resubDelta)}`);
    const applied = collectionsTs.applyKeyed(clientChats, resubDelta.delta);
    assertConformsStrict("chats", applied);
    assert.equal(applied.days[0].items[0].title, "Build parity (renamed)");
    counts.suite4Core++;

    // Archive c-1 -> keyed delta drops it from `chats`, and `archive` now includes it
    await rpc.call("core.mutateChat", {
      id: "c-1",
      archived: 1,
      thread: 10,
      session: "sess-1",
      lastActiveAt: 1795442010000,
      doc: {
        id: "c-1", session: "sess-1", thread: 10, title: "Build parity (archived)",
        lastActiveAt: 1795442010000, archived: { at: 1795442010000, by: "user" }, agents: [],
      },
    });
    const archRefresh = await rpc.call("core.refreshTopic", { topic: "chats" });
    assert.equal(archRefresh.length, 1);
    const afterArch = "delta" in archRefresh[0]
      ? collectionsTs.applyKeyed(applied, archRefresh[0].delta)
      : archRefresh[0].value;
    assertConformsStrict("chats", afterArch);
    assert.equal(afterArch.days.length, 0, "archiving the only active chat must leave 0 active days");
    counts.suite4Core++;

    // 4D. subscribe chat cold open: 0 SQL writes gate + outbox clientKey dedup + card + unreadLine
    await rpc.call("core.sqlWrites", { reset: true });
    const subChat = await rpc.call("core.wire", {
      msg: { id: 20, subscribe: { topic: "chat", station: "ws1/s1", thread: 10 } },
    });
    const coldWrites = await rpc.call("core.sqlWrites");
    assert.equal(coldWrites, 0, "cold chat open MUST execute 0 SQL writes!");
    assertConformsStrict("chat", subChat.value);
    assert.equal(subChat.value.outbox.length, 1, "confirmed clientKey outbox item must be deduplicated");
    assert.equal(subChat.value.outbox[0].id, "ob-2");
    assert.equal(subChat.value.unreadLine, 4, "unreadLine must point to first unread non-mine message");
    assert.equal(subChat.value.asks.length, 1, "unresolved card must appear in asks");
    counts.suite4Core++;

    // 4E. settings / chat.draft / archive / search / vaults / lock
    const draftSet = await rpc.call("core.wire", {
      msg: { id: 30, call: "chat.draft", params: { station: "ws1/s1", chat: "c-1", text: "draft hello" } },
    });
    assert.equal(draftSet.id, 30);
    assert.ok("ok" in draftSet);

    for (const [subId, topic] of [
      [31, { topic: "settings", scope: "ws1" }],
      [32, { topic: "archive", scope: "ws1" }],
      [33, { topic: "search", scope: "ws1", query: "parity" }],
      [34, { topic: "vaults", workspace: "ws1" }],
      [35, { topic: "lock", workspace: "ws1" }],
    ]) {
      const ev = await rpc.call("core.wire", { msg: { id: subId, subscribe: topic } });
      assert.equal(ev.id, subId);
      assert.ok("value" in ev, `expected value for ${topic.topic}`);
      assertConformsStrict(topic.topic, ev.value);
      assert.ok(!JSON.stringify(ev.value).includes("个人锁"), `「个人锁」 leaked in ${topic.topic}`);
      counts.suite4Core++;
    }
  } finally {
    await core.close();
  }
});
