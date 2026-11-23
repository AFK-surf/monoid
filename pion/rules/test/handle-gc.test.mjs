// Stress & correctness tests for Pion rules Wasm handle table reuse (free-list) and bounded linear memory.
// Run with `node --test pion/rules/test/handle-gc.test.mjs` (spawns a child with --expose-gc for FinalizationRegistry).
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import fs from "node:fs";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

import { createPionRuntime } from "../js/pion_wasm_rt.mjs";
import * as pionRules from "../js/rules-wasm.mjs";

const wasmPath = fileURLToPath(new URL("../js/rules.wasm", import.meta.url));

const crypto = {
  sha256Hex: (s) => createHash("sha256").update(s).digest("hex"),
  sigValid: () => true,
  validKeyId: (k) => typeof k === "string" && k.startsWith("ed25519:"),
  endpointProof: () => true,
  taggedSigValid: () => true,
};

function makeGenesis(ws = "01HGC000000000000000000000") {
  const key = "ed25519:" + "11".repeat(32);
  const dev = "22".repeat(32);
  const st = "33".repeat(32);
  return {
    v: 1,
    ws,
    seq: 0,
    prev: null,
    at: 1000,
    kind: "genesis",
    body: {
      owner: "o",
      origins: ["https://app.still.fail"],
      rp_id: "app.still.fail",
      cloud_keys: { keys: [] },
      members: [{ sub: "o", email: "o@x", role: "owner" }],
      devices: [{ id: dev, sub: "o", kind: "app", label: "app", sign_key: key }],
      passkeys: [],
      stations: [{ key: st, name: "s0" }],
      gateways: [],
    },
    sig: { key, alg: "Ed25519", sig: "00".repeat(64) },
  };
}

test("double-free guard: freeing the same lock/carried handle twice never causes slot aliasing", () => {
  const mod = new WebAssembly.Module(fs.readFileSync(wasmPath));
  const rt = createPionRuntime();
  let inBytes = new Uint8Array(0);
  let outStr = "";
  const encoder = new TextEncoder();
  const decoder = new TextDecoder("utf-8", { fatal: false });
  let mem = null;
  rt.imports.pion_rt.rules_in_len = () => inBytes.length;
  rt.imports.pion_rt.rules_in_copy = (dst) => {
    if (inBytes.length > 0) new Uint8Array(mem.buffer, Number(dst), inBytes.length).set(inBytes);
  };
  rt.imports.pion_rt.rules_out_set = (ptr, len) => {
    outStr = len > 0 ? decoder.decode(new Uint8Array(mem.buffer, Number(ptr), Number(len))) : "";
  };
  rt.imports.pion_rt.rules_sha256_hex_into = (ptr, len, dst) => {
    const s = len > 0 ? decoder.decode(new Uint8Array(mem.buffer, Number(ptr), Number(len))) : "";
    const hex = createHash("sha256").update(s).digest("hex");
    new Uint8Array(mem.buffer, Number(dst), 64).set(encoder.encode(hex));
    return 64;
  };
  let cbBytes = new Uint8Array(0);
  rt.imports.pion_rt.rules_cb_copy = (dst) => {
    if (cbBytes.length > 0) new Uint8Array(mem.buffer, Number(dst), cbBytes.length).set(cbBytes);
  };
  rt.imports.pion_rt.rules_sig_valid = () => 1;
  rt.imports.pion_rt.rules_sig_valid_ed = () => 1;
  rt.imports.pion_rt.rules_valid_key_id = () => 1;
  rt.imports.pion_rt.rules_endpoint_proof = () => 1;
  rt.imports.pion_rt.rules_record_sig_valid = () => 1;
  rt.imports.pion_rt.rules_tagged_sig_valid = () => 1;

  const inst = new WebAssembly.Instance(mod, rt.imports);
  rt.bindExports(inst.exports);
  mem = inst.exports.memory;
  inst.exports.main(0, 0n);
  const exp = inst.exports;

  const callJson = (fn, payload) => {
    inBytes = encoder.encode(JSON.stringify(payload));
    outStr = "";
    exp[fn]();
    return JSON.parse(outStr);
  };

  const callCarried = (entries) => {
    inBytes = encoder.encode(JSON.stringify(entries));
    return Number(exp.wasm_carried());
  };

  const g = makeGenesis();
  // Lock handles: allocate h0, double-free h0, allocate h1 & h2 -> h1 reuses h0, h2 gets fresh slot
  const r0 = callJson("wasm_fold_held", { entries: [g], now: null });
  assert.equal(typeof r0.handle, "number");
  assert.equal(exp.lock_handle_table_len(), 1);
  assert.equal(exp.lock_handle_live_count(), 1);

  exp.free_lock_handle(r0.handle);
  exp.free_lock_handle(r0.handle); // double-free must be a no-op!
  exp.free_lock_handle(-1);        // out-of-bounds must be a no-op
  exp.free_lock_handle(999);
  assert.equal(exp.lock_handle_live_count(), 0);

  const r1 = callJson("wasm_fold_held", { entries: [g], now: null });
  const r2 = callJson("wasm_fold_held", { entries: [g], now: null });
  assert.equal(r1.handle, r0.handle, "first realloc reuses freed slot");
  assert.notEqual(r2.handle, r1.handle, "second realloc must NOT alias first slot after double-free");
  assert.equal(exp.lock_handle_table_len(), 2);
  assert.equal(exp.lock_handle_live_count(), 2);

  // Carried handles: allocate c0, double-free c0, allocate c1 & c2
  const c0 = callCarried([g]);
  assert.equal(typeof c0, "number");
  assert.equal(exp.carried_handle_table_len(), 1);
  assert.equal(exp.carried_handle_live_count(), 1);

  exp.free_carried_handle(c0);
  exp.free_carried_handle(c0); // double-free must be a no-op!
  exp.free_carried_handle(-1);
  exp.free_carried_handle(999);
  assert.equal(exp.carried_handle_live_count(), 0);

  const c1 = callCarried([g]);
  const c2 = callCarried([g]);
  assert.equal(c1, c0, "first carried realloc reuses freed slot");
  assert.notEqual(c2, c1, "second carried realloc must NOT alias first slot after double-free");
  assert.equal(exp.carried_handle_table_len(), 2);
  assert.equal(exp.carried_handle_live_count(), 2);
});

test("long-lived GC stress: 3000 fold_held_js + carried_js calls converge with bounded handle tables and Wasm memory", () => {
  const rulesUrl = JSON.stringify(new URL("../js/rules-wasm.mjs", import.meta.url).href);
  const script = `
    import { createHash } from "node:crypto";
    const r = await import(${rulesUrl});
    const crypto = {
      sha256Hex: (s) => createHash("sha256").update(s).digest("hex"),
      sigValid: () => true,
      validKeyId: (k) => typeof k === "string" && k.startsWith("ed25519:"),
      endpointProof: () => true,
      taggedSigValid: () => true,
    };
    const g = ${JSON.stringify(makeGenesis())};
    const drain = async () => {
      globalThis.gc();
      await new Promise((res) => setImmediate(res));
      globalThis.gc();
      await new Promise((res) => setImmediate(res));
    };
    const runBatch = (n) => {
      for (let i = 0; i < n; i++) {
        const h = r.fold_held_js([g], null, crypto);
        if ("error" in h) throw new Error(h.error);
        const c = r.carried_js([g], crypto);
        if (!c) throw new Error("missing carried");
      }
    };
    // Warmup: 500 iterations in batches of 50
    for (let b = 0; b < 10; b++) {
      runBatch(50);
      await drain();
    }
    const afterWarmup = r.wasmMemoryStats();

    // Steady-state: 2500 more iterations (3000 total) in batches of 50
    for (let b = 0; b < 50; b++) {
      runBatch(50);
      await drain();
    }
    const afterStress = r.wasmMemoryStats();
    console.log(JSON.stringify({ afterWarmup, afterStress }));
  `;
  const out = execFileSync(process.execPath, ["--expose-gc", "--input-type=module", "-e", script], {
    encoding: "utf8",
  });
  const { afterWarmup, afterStress } = JSON.parse(out.trim());
  console.log(
    `handle-gc stress (3000 iters): warmup={lockLen:${afterWarmup.lockTableLen}, carriedLen:${afterWarmup.carriedTableLen}, mem:${(afterWarmup.memoryBytes / 1024 / 1024).toFixed(2)} MiB} -> stress={lockLen:${afterStress.lockTableLen}, carriedLen:${afterStress.carriedTableLen}, mem:${(afterStress.memoryBytes / 1024 / 1024).toFixed(2)} MiB}`,
  );
  assert.ok(afterStress.initialized);
  assert.ok(
    afterStress.lockTableLen <= 250,
    `lock_handles table grew unbounded: ${afterStress.lockTableLen} after 3000 allocs`,
  );
  assert.ok(
    afterStress.carriedTableLen <= 250,
    `carried_handles table grew unbounded: ${afterStress.carriedTableLen} after 3000 allocs`,
  );
  // Steady-state memory after 2500 more calls must stay converged (<= 2x warmup, never linear growth)
  assert.ok(
    afterStress.memoryBytes <= Math.max(afterWarmup.memoryBytes * 2, 16 * 1024 * 1024),
    `Wasm linear memory grew excessively: warmup=${afterWarmup.memoryBytes} -> stress=${afterStress.memoryBytes}`,
  );
  // Also verify handle table length did not grow significantly between warmup (500) and stress (3000)
  assert.ok(
    afterStress.lockTableLen <= afterWarmup.lockTableLen + 100,
    `lockTableLen drifted: warmup=${afterWarmup.lockTableLen} -> stress=${afterStress.lockTableLen}`,
  );
  assert.ok(
    afterStress.carriedTableLen <= afterWarmup.carriedTableLen + 100,
    `carriedTableLen drifted: warmup=${afterWarmup.carriedTableLen} -> stress=${afterStress.carriedTableLen}`,
  );
});
