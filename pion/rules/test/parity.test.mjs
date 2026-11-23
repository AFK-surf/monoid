// Full differential parity test: pion/rules/js/rules-wasm.mjs vs rules/js/rules.js
// Runs:
//   1. Cloudflare Worker module-load constraint check (zero Math.random / crypto.getRandomValues at import)
//   2. Export surface parity (all 36 functions)
//   3. Direct unit/edge-case parity across form, role, fork, history, lock, vault, carried, supersedes
//   4. Full station/test/rules-fork-check.ts random & scripted worlds (lock, person, M2/M5/M6/M7/M8/M9)
//      comparing Pion Wasm against BOTH MoonBit JS (every call) and the TS models (0 diffs)
//   5. Latency benchmark (Pion Wasm vs MoonBit JS) + .wasm artifact size report
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import fs from "node:fs";
import module from "node:module";
import { test } from "node:test";
import { fileURLToPath, pathToFileURL } from "node:url";

const wasmPath = fileURLToPath(new URL("../js/rules.wasm", import.meta.url));
const pionUrl = new URL("../js/rules-wasm.mjs", import.meta.url).href;
const mbUrl = new URL("../../../rules/js/rules.js", import.meta.url).href;

// 1. Verify zero RNG calls during module load (Cloudflare Worker constraint)
let pionRules;
{
  const origRandom = Math.random;
  const origGetRandomValues = globalThis.crypto?.getRandomValues?.bind(globalThis.crypto);
  Math.random = () => { throw new Error("Math.random called at module load!"); };
  if (globalThis.crypto) {
    globalThis.crypto.getRandomValues = () => { throw new Error("crypto.getRandomValues called at module load!"); };
  }
  try {
    pionRules = await import(pionUrl);
  } finally {
    Math.random = origRandom;
    if (globalThis.crypto && origGetRandomValues) {
      globalThis.crypto.getRandomValues = origGetRandomValues;
    }
  }
}

const mbRules = await import(mbUrl);

// Helper to normalize JS values for deep comparison (ignoring opaque `rules` handle internals)
function stripHandles(v) {
  if (v === null || v === undefined || typeof v !== "object") return v;
  if (Array.isArray(v)) return v.map(stripHandles);
  const out = {};
  for (const k of Object.keys(v)) {
    if (k === "rules") continue;
    out[k] = stripHandles(v[k]);
  }
  return out;
}

const EXPECTED_EXPORTS = [
  "canonical_of", "entry_text_of", "lower_role",
  "fold_js", "admit_js", "genesis_js", "apply_js", "signer_js", "admit_one_js",
  "copied_js", "stepped_js", "fold_held_js", "person_fold_js", "admit_person_js",
  "cert_ok_js", "vault_ok_js", "item_ok_js", "browser_listing_ok_js", "signer_of_js",
  "vault_supersedes_js", "item_supersedes_js",
  "tie_of_js", "fork_before_js", "lock_chain_js", "person_chain_js",
  "roster_js", "carried_js", "roster_carried_js", "roster_moved_js",
  "state4_js", "state4_carried_js", "state4_moved_js",
  "bind_digest_js", "ws_tag_js", "body_hash_js", "body_refusal_js",
];

test("export surface parity (all 36 functions) and Cloudflare Worker zero-RNG load", () => {
  for (const name of EXPECTED_EXPORTS) {
    assert.equal(typeof mbRules[name], "function", `MoonBit missing ${name}`);
    assert.equal(typeof pionRules[name], "function", `Pion missing ${name}`);
  }
  const wasmSize = fs.statSync(wasmPath).size;
  assert.ok(wasmSize > 0, "rules.wasm must exist and be non-empty");
  console.log(`rules.wasm size: ${wasmSize} bytes (${(wasmSize / 1024).toFixed(1)} KiB)`);
});

test("form, role, fork, supersedes, and edge-case parity", () => {
  const formCases = [
    null, true, false, 0, -0, 1, -1, 42, 9007199254740991, -9007199254740991,
    9007199254740992, 1.5, NaN, Infinity, -Infinity,
    "", "hello", "a\"b\\c\b\f\n\r\t\u0000\u001f",
    "名字 😀", "\ud800", "\udfff", "\ud800x\udfff", "\ud800\udc00",
    [], [1, "a", null, true, { z: 1, a: 2 }],
    { b: 1, a: 2, "\ud800": 3, "😀": 4, "\uffff": 5, undef: undefined },
    undefined, () => {}, Symbol("s"),
  ];
  for (const v of formCases) {
    assert.equal(pionRules.canonical_of(v), mbRules.canonical_of(v), `canonical_of(${String(v)})`);
    assert.equal(pionRules.entry_text_of(v), mbRules.entry_text_of(v), `entry_text_of(${String(v)})`);
  }

  const entry = { v: 1, ws: "w", seq: 0, prev: null, at: 100, kind: "genesis", body: { b: 1, a: "😀\ud800" }, sig: { key: "k" }, extra: 9 };
  assert.equal(pionRules.entry_text_of(entry), mbRules.entry_text_of(entry));

  const roles = ["owner", "admin", "member", "viewer", "unknown", ""];
  for (const a of roles) {
    for (const b of roles) {
      assert.equal(pionRules.lower_role(a, b), mbRules.lower_role(a, b), `lower_role(${a},${b})`);
    }
  }

  const c = { sha256Hex: (s) => createHash("sha256").update(s).digest("hex") };
  assert.equal(pionRules.tie_of_js("a".repeat(64), "ed25519:" + "b".repeat(64), c), mbRules.tie_of_js("a".repeat(64), "ed25519:" + "b".repeat(64), c));
  assert.equal(pionRules.ws_tag_js("ws1", "c".repeat(64), c), mbRules.ws_tag_js("ws1", "c".repeat(64), c));
  assert.deepEqual(pionRules.bind_digest_js("ws1", "alice", "a".repeat(64), "b".repeat(64), c), mbRules.bind_digest_js("ws1", "alice", "a".repeat(64), "b".repeat(64), c));

  const children = [
    { weight: 3, removal: false, tie: "b".repeat(64), hash: "b".repeat(64) },
    { weight: 2, removal: true, tie: "a".repeat(64), hash: "a".repeat(64) },
    { weight: 2, removal: false, tie: "a".repeat(64), hash: "b".repeat(64) },
    { weight: 2, removal: false, tie: "a".repeat(64), hash: "a".repeat(64) },
  ];
  for (const a of children) {
    for (const b of children) {
      assert.equal(pionRules.fork_before_js(a, b), mbRules.fork_before_js(a, b));
    }
  }

  const vs = [
    { seq: 1, epoch: 1, name: "a" },
    { seq: 1, epoch: 1, name: "bb" },
    { seq: 1, epoch: 2, name: "a" },
    { seq: 1, epoch: 1, deleted: true },
    { seq: 2, epoch: 0, name: "a" },
  ];
  for (const a of vs) {
    for (const b of vs) {
      assert.equal(pionRules.vault_supersedes_js(a, b), mbRules.vault_supersedes_js(a, b));
    }
  }
  const items = [
    { version: 0, epoch: 1, ct: "x" },
    { version: 0, epoch: 1, ct: "yy" },
    { version: 0, epoch: 1, deleted: true },
    { version: 1, epoch: 0, ct: "a" },
  ];
  for (const a of items) {
    for (const b of items) {
      assert.equal(pionRules.item_supersedes_js(a, b), mbRules.item_supersedes_js(a, b));
    }
  }
});

test("lock & vault random chains/certs/vaults/items parity against MoonBit JS", async () => {
  const { endpointBytes, endpointProof, sigValid, validKeyId } = await import("../../../shared/lock.ts");
  const { signedBytes, TAG } = await import("../../../station/src/vault/crypto.ts");
  const { WS, bases, genesisOf, key, nextOf, people, rng, signers, spare } = await import("../../../station/test/lock-chains.ts");

  const crypto = {
    sha256Hex: (s) => createHash("sha256").update(s).digest("hex"),
    sigValid,
    validKeyId,
    endpointProof,
    recordSigValid: (sig, tag, text) => {
      const digest = createHash("sha256").update(text).digest();
      const bytes = Buffer.concat([Buffer.from(tag), Buffer.from([0]), digest]);
      return sigValid(sig, bytes.toString("hex"), [], "", false);
    },
  };

  let lockChecks = 0;
  let vaultChecks = 0;
  for (let seed = 1; seed <= 10; seed++) {
    const r = rng(seed);
    const kept = [genesisOf(r)];
    // Check genesis_js + apply_js + signer_js
    const gMb = mbRules.genesis_js(kept[0], crypto);
    const gPi = pionRules.genesis_js(kept[0], crypto);
    assert.deepEqual(stripHandles(gPi), stripHandles(gMb), `genesis_js seed ${seed}`);
    let hMb = gMb.rules;
    let hPi = gPi.rules;

    for (let i = 1; i <= 20; i++) {
      const next = nextOf(r, kept.at(-1), i);
      const tried = [...kept, next];
      for (const now of [null, 1000 + 20 * 60]) {
        const fMb = mbRules.fold_js(tried, now, crypto);
        const fPi = pionRules.fold_js(tried, now, crypto);
        assert.deepEqual(stripHandles(fPi), stripHandles(fMb), `fold_js seed ${seed} i=${i} now=${now}`);
        const aMb = mbRules.apply_js(hMb, next, now, crypto);
        const aPi = pionRules.apply_js(hPi, next, now, crypto);
        assert.deepEqual(stripHandles(aPi), stripHandles(aMb), `apply_js seed ${seed} i=${i} now=${now}`);
        lockChecks += 2;
      }
      const resMb = mbRules.apply_js(hMb, next, null, crypto);
      const resPi = pionRules.apply_js(hPi, next, null, crypto);
      if ("state" in resMb) {
        kept.push(next);
        hMb = resMb.rules;
        hPi = resPi.rules;
      }
    }
    for (const k of [...signers, ...spare]) {
      assert.deepEqual(pionRules.signer_js(hPi, k.id, null), mbRules.signer_js(hMb, k.id, null));
      assert.deepEqual(pionRules.signer_js(hPi, k.id, 1000 + 35 * 86400), mbRules.signer_js(hMb, k.id, 1000 + 35 * 86400));
    }
    const queries = [];
    for (const [i, who] of [...bases, ...spare].entries()) {
      const endpoint = spare[(i + 1) % spare.length].hex;
      const proof = who.sign(endpointBytes(WS, endpoint));
      for (const sub of people) {
        queries.push({ sub, endpoint, base: who.hex, proof, now: 2000 }, { sub, endpoint: who.hex, now: 1000 + 35 * 86400 });
      }
    }
    assert.deepEqual(pionRules.admit_js(kept, null, queries, crypto), mbRules.admit_js(kept, null, queries, crypto), `admit_js seed ${seed}`);
    for (const q of queries.slice(0, 12)) {
      assert.deepEqual(pionRules.admit_one_js(hPi, q, q.now, crypto), mbRules.admit_one_js(hMb, q, q.now, crypto), `admit_one_js seed ${seed}`);
    }

    // Build LockState Map view for vault checks
    const st = mbRules.fold_js(kept, null, crypto).state;
    const lockView = {
      ws: st.ws,
      members: new Map(st.members),
      devices: new Map(st.devices),
      signKeys: new Map(st.signKeys),
    };
    for (const k of [...signers, ...spare]) {
      assert.deepEqual(pionRules.signer_of_js(lockView, k.id), mbRules.signer_of_js(lockView, k.id));
    }
    const box = `x25519:${key(70).hex}`;
    const certObj = { v: 1, ws: WS, device: bases[0].hex, box, at: 1000 };
    const certSigned = { ...certObj, sig: { key: signers[0].id, alg: "Ed25519", sig: signers[0].sign(Buffer.from(signedBytes(certObj, TAG.box))) } };
    for (const ever of [false, true]) {
      assert.equal(pionRules.cert_ok_js(lockView, certSigned, ever, crypto), mbRules.cert_ok_js(lockView, certSigned, ever, crypto));
      vaultChecks++;
    }
    const vid = "v_01HZZZZZZZZZZZZZZZZZZZZZZZ";
    const v0Obj = { v: 1, ws: WS, id: vid, seq: 0, owner: people[0], name: "Work", members: [people[0]], epoch: 0, keys: [{ cert: certSigned, wrapped: "A".repeat(40) }], at: 1000 };
    const v0 = { ...v0Obj, sig: { key: signers[0].id, alg: "Ed25519", sig: signers[0].sign(Buffer.from(signedBytes(v0Obj, TAG.vault))) } };
    for (const copy of [false, true]) {
      assert.equal(pionRules.vault_ok_js(lockView, null, v0, copy, crypto), mbRules.vault_ok_js(lockView, null, v0, copy, crypto));
      vaultChecks++;
    }
    const i0Obj = { v: 1, ws: WS, vault: vid, id: "i_01HZZZZZZZZZZZZZZZZZZZZZZZ", version: 0, epoch: 0, ct: "B".repeat(48), at: 1001, listing: { name: "GH", kind: "browser", modes: ["browser"], hosts: ["github.com"] } };
    const i0 = { ...i0Obj, sig: { key: signers[0].id, alg: "Ed25519", sig: signers[0].sign(Buffer.from(signedBytes(i0Obj, TAG.item))) } };
    assert.equal(pionRules.item_ok_js(lockView, v0, null, i0, false, crypto), mbRules.item_ok_js(lockView, v0, null, i0, false, crypto));
    assert.equal(pionRules.browser_listing_ok_js(i0Obj.listing), mbRules.browser_listing_ok_js(i0Obj.listing));
    vaultChecks += 2;
  }
  console.log(`lock/vault parity: ${lockChecks} lock fold/apply checks, ${vaultChecks} vault checks, 0 diffs`);
});

test("full rules-fork-check.ts worlds parity (Pion Wasm vs MoonBit JS vs TS models) + latency comparison", async () => {
  // Dual-execution proxy: intercepts rules/js/rules.js inside rules-fork-check.ts so EVERY call runs both
  // MoonBit JS and Pion Wasm on identical inputs, asserts 0 diffs, and times both.
  const pairHandle = new WeakMap();
  const stats = { calls: 0, diffs: [], mbMs: 0, pionMs: 0, byFn: {} };

  function recordCall(name, fn) {
    return (...args) => {
      const mbArgs = args.map((a) => (a && typeof a === "object" && pairHandle.has(a) ? pairHandle.get(a).mb : a));
      const piArgs = args.map((a) => (a && typeof a === "object" && pairHandle.has(a) ? pairHandle.get(a).pi : a));

      const t0 = performance.now();
      const mbOut = mbRules[name](...mbArgs);
      const t1 = performance.now();
      const piOut = pionRules[name](...piArgs);
      const t2 = performance.now();

      stats.calls++;
      stats.mbMs += t1 - t0;
      stats.pionMs += t2 - t1;
      const entry = stats.byFn[name] ?? (stats.byFn[name] = { n: 0, mbMs: 0, pionMs: 0 });
      entry.n++;
      entry.mbMs += t1 - t0;
      entry.pionMs += t2 - t1;

      if (name === "carried_js") {
        const proxy = {};
        pairHandle.set(proxy, { mb: mbOut, pi: piOut });
        return proxy;
      }

      const mbClean = stripHandles(mbOut);
      const piClean = stripHandles(piOut);
      try {
        assert.deepEqual(piClean, mbClean);
      } catch (e) {
        if (stats.diffs.length < 10) {
          stats.diffs.push(`${name}: ${e.message.slice(0, 300)}`);
        }
      }

      if (piOut && typeof piOut === "object" && "rules" in piOut && mbOut && typeof mbOut === "object" && "rules" in mbOut) {
        const proxy = {};
        pairHandle.set(proxy, { mb: mbOut.rules, pi: piOut.rules });
        return { ...piOut, rules: proxy };
      }
      return piOut;
    };
  }

  const dualExports = {};
  for (const name of EXPECTED_EXPORTS) {
    dualExports[name] = recordCall(name);
  }
  globalThis.__PION_RULES_DUAL__ = dualExports;

  const hook = module.registerHooks({
    resolve(specifier, context, nextResolve) {
      if (specifier.endsWith("rules/js/rules.js") && context.parentURL && context.parentURL.includes("rules-fork-check")) {
        return { url: "pion-dual://rules", shortCircuit: true };
      }
      return nextResolve(specifier, context);
    },
    load(url, context, nextLoad) {
      if (url === "pion-dual://rules") {
        const code = EXPECTED_EXPORTS.map((n) => `export const ${n} = globalThis.__PION_RULES_DUAL__.${n};`).join("\n");
        return { format: "module", source: code, shortCircuit: true };
      }
      return nextLoad(url, context);
    },
  });

  try {
    // Load rules-fork-check.ts with a query string so Node loads a fresh instance bound to our dual hook
    const checkMod = await import("../../../station/test/rules-fork-check.ts?dual=1");
    const { VARIANTS } = await import("../../../station/test/lock-fork-choice-model.ts");
    const { V3 } = await import("../../../station/test/lock-roster-model.ts");

    const LOCK_V = VARIANTS.filter((v) => v.removal === "device" && v.hashfield === "as-is").map((v) => ({ ...v, tie: "signer" }));
    const FAMILIES = ["free", "faults"];
    const LOCK_SEEDS = Number(process.env.PARITY_LOCK_SEEDS ?? 6);
    const PERSON_SEEDS = Number(process.env.PARITY_PERSON_SEEDS ?? 8);
    const STEPS = Number(process.env.PARITY_STEPS ?? 80);
    const SCRIPTED = Number(process.env.PARITY_SCRIPTED ?? 6);

    let totalWorlds = 0;
    let totalChecks = 0;
    let totalBranched = 0;
    let totalRefused = 0;
    let totalStatements = 0;
    let totalCarried = 0;
    const modelDiffs = [];

    const accum = (o) => {
      totalWorlds += o.worlds;
      totalChecks += o.checks;
      totalBranched += o.branched;
      totalRefused += o.refusedSeen;
      totalStatements += o.statements;
      totalCarried += o.more.carried;
      for (const d of o.differ) modelDiffs.push(d);
    };

    for (const v of LOCK_V) {
      for (const family of FAMILIES) {
        accum(checkMod.lockWorlds(v, family, 1, LOCK_SEEDS, STEPS));
      }
    }
    for (const v of V3) {
      for (const family of FAMILIES) {
        accum(checkMod.personWorlds(v, family, 1, PERSON_SEEDS, STEPS));
      }
    }
    accum(checkMod.scriptedWorlds(1, SCRIPTED));

    const avgMbUs = (stats.mbMs * 1000) / Math.max(1, stats.calls);
    const avgPiUs = (stats.pionMs * 1000) / Math.max(1, stats.calls);
    console.log(
      `parity worlds=${totalWorlds} chains=${totalChecks} branched=${totalBranched} refused=${totalRefused} statements=${totalStatements} carried=${totalCarried} | dual_calls=${stats.calls} pion_vs_mb_diffs=${stats.diffs.length} model_diffs=${modelDiffs.length}`,
    );
    console.log(
      `latency (total across ${stats.calls} calls): MoonBit JS ${stats.mbMs.toFixed(1)} ms (${avgMbUs.toFixed(1)} us/call) vs Pion Wasm ${stats.pionMs.toFixed(1)} ms (${avgPiUs.toFixed(1)} us/call)`,
    );
    for (const [fn, s] of Object.entries(stats.byFn).sort((a, b) => b[1].n - a[1].n)) {
      console.log(`  ${fn}: ${s.n} calls | MB ${(s.mbMs * 1000 / s.n).toFixed(1)} us/call | Pion ${(s.pionMs * 1000 / s.n).toFixed(1)} us/call`);
    }

    assert.equal(stats.diffs.length, 0, `Pion Wasm vs MoonBit JS diffs:\n${stats.diffs.join("\n")}`);
    assert.equal(modelDiffs.length, 0, `Pion Wasm vs TS model diffs:\n${modelDiffs.slice(0, 5).join("\n")}`);
    assert.ok(totalWorlds > 0 && totalChecks > 0 && totalBranched > 0 && totalRefused > 0 && totalCarried > 0);
  } finally {
    hook.deregister();
    delete globalThis.__PION_RULES_DUAL__;
  }
});
