// Thin synchronous JS/Wasm wrapper for pion/rules (compiled to js/rules.wasm).
// Exports the exact 36-function synchronous API of rules/js/rules.js.
// Safe for Cloudflare Workers: module loading performs zero Math.random / crypto.getRandomValues calls;
// Wasm instantiation and runtime binding happen lazily on first call.
import { createPionRuntime } from "./pion_wasm_rt.mjs";

const encoder = new TextEncoder();
const decoder = new TextDecoder("utf-8", { fatal: false });

let preloadedWasm = null;
let inst = null;
let mem = null;
let inBytes = new Uint8Array(0);
let outStr = "";
let cbBytes = new Uint8Array(0);
let curCrypto = null;

const lockRegistry = typeof FinalizationRegistry === "function"
  ? new FinalizationRegistry((id) => { if (inst) inst.exports.free_lock_handle(id); })
  : null;
const carriedRegistry = typeof FinalizationRegistry === "function"
  ? new FinalizationRegistry((id) => { if (inst) inst.exports.free_carried_handle(id); })
  : null;

/**
 * Optional for Cloudflare Workers / browsers: supply a pre-compiled WebAssembly.Module or Uint8Array
 * before the first rules call. Does not instantiate until first use.
 */
export function initWasm(wasmModuleOrBytes) {
  preloadedWasm = wasmModuleOrBytes;
  inst = null;
  mem = null;
}

/**
 * Eagerly read and compile `rules.wasm` in Node at startup so no synchronous `fs` I/O occurs
 * during live request handling on the station's main thread. Performs zero RNG calls.
 */
export function preloadWasm() {
  if (preloadedWasm === null) preloadedWasm = loadWasmModule();
}

/**
 * Diagnostic handle-table & linear-memory stats (does not instantiate Wasm if not yet loaded).
 */
export function wasmMemoryStats() {
  if (inst === null || mem === null) {
    return { initialized: false, memoryBytes: 0, lockTableLen: 0, lockLive: 0, carriedTableLen: 0, carriedLive: 0 };
  }
  return {
    initialized: true,
    memoryBytes: mem.buffer.byteLength,
    lockTableLen: inst.exports.lock_handle_table_len(),
    lockLive: inst.exports.lock_handle_live_count(),
    carriedTableLen: inst.exports.carried_handle_table_len(),
    carriedLive: inst.exports.carried_handle_live_count(),
  };
}

function readMemStr(ptr, len) {
  const n = Number(len);
  if (n <= 0) return "";
  return decoder.decode(new Uint8Array(mem.buffer, Number(ptr), n));
}

function loadWasmModule() {
  if (preloadedWasm instanceof WebAssembly.Module) return preloadedWasm;
  if (preloadedWasm instanceof Uint8Array || preloadedWasm instanceof ArrayBuffer) {
    return new WebAssembly.Module(preloadedWasm);
  }
  if (typeof process !== "undefined" && typeof process.getBuiltinModule === "function") {
    const fs = process.getBuiltinModule("node:fs");
    const url = process.getBuiltinModule("node:url");
    const wasmPath = url.fileURLToPath(new URL("./rules.wasm", import.meta.url));
    return new WebAssembly.Module(fs.readFileSync(wasmPath));
  }
  throw new Error("pion/rules/js/rules-wasm.mjs: call initWasm(moduleOrBytes) in non-Node environments");
}

function ensureInit() {
  if (inst !== null) return inst.exports;
  const rt = createPionRuntime();
  rt.imports.pion_rt.rules_in_len = () => inBytes.length;
  rt.imports.pion_rt.rules_in_copy = (dst) => {
    if (inBytes.length > 0) {
      new Uint8Array(mem.buffer).set(inBytes, Number(dst));
    }
  };
  rt.imports.pion_rt.rules_out_set = (src, len) => {
    outStr = readMemStr(src, len);
  };
  rt.imports.pion_rt.rules_cb_copy = (dst) => {
    if (cbBytes.length > 0) {
      new Uint8Array(mem.buffer).set(cbBytes, Number(dst));
    }
  };
  rt.imports.pion_rt.rules_sha256_hex = (ptr, len) => {
    const res = String(curCrypto.sha256Hex(readMemStr(ptr, len)));
    cbBytes = encoder.encode(res);
    return cbBytes.length;
  };
  rt.imports.pion_rt.rules_sig_valid = (sp, sl, hp, hl, op, ol, rp, rl, pk) => {
    const sig = JSON.parse(readMemStr(sp, sl));
    const hash = readMemStr(hp, hl);
    const origins = JSON.parse(readMemStr(op, ol));
    const rpId = readMemStr(rp, rl);
    return curCrypto.sigValid(sig, hash, origins, rpId, pk !== 0) ? 1 : 0;
  };
  rt.imports.pion_rt.rules_valid_key_id = (ptr, len) => {
    return curCrypto.validKeyId(readMemStr(ptr, len)) ? 1 : 0;
  };
  rt.imports.pion_rt.rules_endpoint_proof = (wp, wl, bp, bl, ep, el, pp, pl) => {
    return curCrypto.endpointProof(
      readMemStr(wp, wl),
      readMemStr(bp, bl),
      readMemStr(ep, el),
      readMemStr(pp, pl),
    ) ? 1 : 0;
  };
  rt.imports.pion_rt.rules_tagged_sig_valid = (kp, kl, sp, sl, tp, tl, dp, dl) => {
    if (typeof curCrypto.taggedSigValid !== "function") return 0;
    return curCrypto.taggedSigValid(
      readMemStr(kp, kl),
      readMemStr(sp, sl),
      readMemStr(tp, tl),
      readMemStr(dp, dl),
    ) === true ? 1 : 0;
  };
  rt.imports.pion_rt.rules_record_sig_valid = (sp, sl, tp, tl, xp, xl) => {
    const sig = JSON.parse(readMemStr(sp, sl));
    const tag = readMemStr(tp, tl);
    const text = readMemStr(xp, xl);
    return curCrypto.recordSigValid(sig, tag, text) ? 1 : 0;
  };

  const mod = loadWasmModule();
  inst = new WebAssembly.Instance(mod, rt.imports);
  rt.bindExports(inst.exports);
  mem = inst.exports.memory;
  inst.exports.main(0, 0n);
  return inst.exports;
}

class NotLockValue extends Error {}

function encodeStrict(v) {
  if (v === null) return "null";
  const t = typeof v;
  if (t === "boolean") return v ? "true" : "false";
  if (t === "number") {
    if (Number.isFinite(v)) return Object.is(v, -0) ? "0" : String(v);
    if (Number.isNaN(v)) return '{"$__pion_num__":"NaN"}';
    return v > 0 ? '{"$__pion_num__":"Inf"}' : '{"$__pion_num__":"-Inf"}';
  }
  if (t === "string") return JSON.stringify(v);
  if (Array.isArray(v)) {
    let out = "[";
    for (let i = 0; i < v.length; i++) {
      if (i > 0) out += ",";
      out += encodeStrict(v[i]);
    }
    return out + "]";
  }
  if (t === "object") {
    const keys = Object.keys(v);
    let out = "{";
    let first = true;
    for (let i = 0; i < keys.length; i++) {
      const k = keys[i];
      const val = v[k];
      if (val === undefined) continue;
      if (!first) out += ",";
      first = false;
      out += JSON.stringify(k) + ":" + encodeStrict(val);
    }
    return out + "}";
  }
  throw new NotLockValue("not a lock value");
}

function encodeRecord(v, nullNone = false) {
  if (v === undefined || (nullNone && v === null)) return null;
  try {
    return encodeStrict(v);
  } catch {
    return null;
  }
}

function encodeEntries(entries) {
  let out = "[";
  for (let i = 0; i < entries.length; i++) {
    if (i > 0) out += ",";
    out += encodeStrict(entries[i]);
  }
  return out + "]";
}

function encodeChains(chains) {
  let out = "[";
  for (let i = 0; i < chains.length; i++) {
    if (i > 0) out += ",";
    out += encodeEntries(chains[i]);
  }
  return out + "]";
}

function encodeBodies(bodies) {
  let out = "[";
  let first = true;
  for (let i = 0; i < bodies.length; i++) {
    let enc;
    try {
      enc = encodeStrict(bodies[i]);
    } catch {
      continue;
    }
    if (!first) out += ",";
    first = false;
    out += enc;
  }
  return out + "]";
}

function encodeTexts(v) {
  if (!Array.isArray(v)) return "[]";
  let out = "[";
  let first = true;
  for (let i = 0; i < v.length; i++) {
    if (typeof v[i] !== "string") continue;
    if (!first) out += ",";
    first = false;
    out += JSON.stringify(v[i]);
  }
  return out + "]";
}

function encodeLockView(lock) {
  const members = [];
  for (const [sub, val] of lock.members) {
    const role = typeof val === "string"
      ? val
      : (val && typeof val === "object" && typeof val.role === "string" ? val.role : "member");
    members.push([sub, role]);
  }
  const devices = [];
  for (const [id, d] of lock.devices) {
    const item = { sub: d.sub, kind: d.kind, own: d.own === true };
    if (typeof d.sign_key === "string") item.sign_key = d.sign_key;
    devices.push([id, item]);
  }
  const signKeys = [];
  for (const [id, had] of lock.signKeys) {
    signKeys.push([id, Array.from(had)]);
  }
  return JSON.stringify({ ws: lock.ws, members, devices, signKeys });
}

function callStr(fnName, payloadStr, crypto = null, arg0 = undefined) {
  const exp = ensureInit();
  const prevCrypto = curCrypto;
  if (crypto !== null) curCrypto = crypto;
  try {
    inBytes = encoder.encode(payloadStr);
    outStr = "";
    if (arg0 === undefined) {
      exp[fnName]();
    } else {
      exp[fnName](arg0);
    }
    return outStr;
  } finally {
    curCrypto = prevCrypto;
  }
}

function callJson(fnName, payloadStr, crypto = null, arg0 = undefined) {
  return JSON.parse(callStr(fnName, payloadStr, crypto, arg0));
}

function wrapLockHandle(id) {
  const obj = { __pion_lock_handle: id };
  if (lockRegistry) lockRegistry.register(obj, id);
  return obj;
}

function wrapCarriedHandle(id) {
  const obj = { __pion_carried_handle: id };
  if (carriedRegistry) carriedRegistry.register(obj, id);
  return obj;
}

function unwrapHeld(res) {
  if ("error" in res) return res;
  const out = { state: res.state, rules: wrapLockHandle(res.handle) };
  if ("on" in res) out.on = res.on;
  if ("root_in" in res) out.root_in = res.root_in;
  return out;
}

// ── Exported API (36 functions matching rules/js/rules.js) ────────────────────────────────────────────────────────

export function canonical_of(v) {
  let enc;
  try {
    enc = encodeStrict(v);
  } catch (e) {
    return "!" + (e instanceof NotLockValue ? e.message : String(e));
  }
  return callStr("wasm_canonical_of", enc);
}

export function entry_text_of(v) {
  let enc;
  try {
    enc = encodeStrict(v);
  } catch (e) {
    return "!" + (e instanceof NotLockValue ? e.message : String(e));
  }
  return callStr("wasm_entry_text_of", enc);
}

export function lower_role(a, b) {
  return callStr("wasm_lower_role", JSON.stringify({ a, b }));
}

export function fold_js(entries, now, crypto) {
  let enc;
  try {
    enc = `{"entries":${encodeEntries(entries)},"now":${typeof now === "number" ? encodeStrict(now) : "null"}}`;
  } catch (e) {
    return { error: e instanceof NotLockValue ? e.message : String(e) };
  }
  return callJson("wasm_fold", enc, crypto);
}

export function admit_js(entries, fold_now, queries, crypto) {
  let enc;
  try {
    const qs = [];
    for (let i = 0; i < queries.length; i++) {
      const q = queries[i];
      qs.push({
        sub: q.sub,
        endpoint: q.endpoint,
        base: typeof q.base === "string" ? q.base : null,
        proof: typeof q.proof === "string" ? q.proof : null,
        now: q.now,
      });
    }
    enc = `{"entries":${encodeEntries(entries)},"fold_now":${typeof fold_now === "number" ? encodeStrict(fold_now) : "null"},"queries":${JSON.stringify(qs)}}`;
  } catch (e) {
    return { error: e instanceof NotLockValue ? e.message : String(e) };
  }
  return callJson("wasm_admit", enc, crypto);
}

export function genesis_js(entry, crypto) {
  let enc;
  try {
    enc = encodeStrict(entry);
  } catch (e) {
    return { error: e instanceof NotLockValue ? e.message : String(e) };
  }
  return unwrapHeld(callJson("wasm_genesis", enc, crypto));
}

export function apply_js(prev, entry, now, crypto) {
  let enc;
  try {
    enc = `{"entry":${encodeStrict(entry)},"now":${typeof now === "number" ? encodeStrict(now) : "null"}}`;
  } catch (e) {
    return { error: e instanceof NotLockValue ? e.message : String(e) };
  }
  return unwrapHeld(callJson("wasm_apply", enc, crypto, prev.__pion_lock_handle));
}

export function signer_js(s, key, now) {
  const enc = `{"key":${JSON.stringify(key)},"now":${typeof now === "number" ? encodeStrict(now) : "null"}}`;
  return callJson("wasm_signer", enc, null, s.__pion_lock_handle);
}

export function admit_one_js(s, who, now, crypto) {
  const payload = JSON.stringify({
    who: {
      sub: who.sub,
      endpoint: who.endpoint,
      base: typeof who.base === "string" ? who.base : null,
      proof: typeof who.proof === "string" ? who.proof : null,
    },
    now,
  });
  return callJson("wasm_admit_one", payload, crypto, s.__pion_lock_handle);
}

export function copied_js() {
  return Number(ensureInit().wasm_copied());
}

export function stepped_js() {
  return Number(ensureInit().wasm_stepped());
}

export function fold_held_js(entries, now, crypto) {
  let enc;
  try {
    enc = `{"entries":${encodeEntries(entries)},"now":${typeof now === "number" ? encodeStrict(now) : "null"}}`;
  } catch (e) {
    return { error: e instanceof NotLockValue ? e.message : String(e) };
  }
  return unwrapHeld(callJson("wasm_fold_held", enc, crypto));
}

export function person_fold_js(entries, sub, crypto) {
  let enc;
  try {
    enc = `{"entries":${encodeEntries(entries)},"sub":${JSON.stringify(sub)}}`;
  } catch (e) {
    return { error: e instanceof NotLockValue ? e.message : String(e) };
  }
  return callJson("wasm_person_fold", enc, crypto);
}

export function admit_person_js(s, who, entries, crypto) {
  let enc;
  try {
    enc = `{"who":${JSON.stringify({
      sub: who.sub,
      endpoint: who.endpoint,
      base: typeof who.base === "string" ? who.base : null,
      proof: typeof who.proof === "string" ? who.proof : null,
    })},"entries":${encodeEntries(entries)}}`;
  } catch (e) {
    return { refusal: e instanceof NotLockValue ? e.message : String(e) };
  }
  return callJson("wasm_admit_person", enc, crypto, s.__pion_lock_handle);
}

export function cert_ok_js(lock, cert, ever, crypto) {
  const c = encodeRecord(cert, false);
  const payload = c === null
    ? `{"lock":${encodeLockView(lock)},"ever":${ever ? "true" : "false"}}`
    : `{"lock":${encodeLockView(lock)},"cert":${c},"ever":${ever ? "true" : "false"}}`;
  return callJson("wasm_cert_ok", payload, crypto);
}

export function vault_ok_js(lock, prev, next, copy, crypto) {
  const p = encodeRecord(prev, true);
  const n = encodeRecord(next, false) ?? "null";
  const payload = p === null
    ? `{"lock":${encodeLockView(lock)},"prev":null,"next":${n},"copy":${copy ? "true" : "false"}}`
    : `{"lock":${encodeLockView(lock)},"prev":${p},"next":${n},"copy":${copy ? "true" : "false"}}`;
  return callJson("wasm_vault_ok", payload, crypto);
}

export function item_ok_js(lock, vault, prev, next, copy, crypto) {
  const v = encodeRecord(vault, false) ?? "null";
  const p = encodeRecord(prev, true);
  const n = encodeRecord(next, false) ?? "null";
  const payload = p === null
    ? `{"lock":${encodeLockView(lock)},"vault":${v},"prev":null,"next":${n},"copy":${copy ? "true" : "false"}}`
    : `{"lock":${encodeLockView(lock)},"vault":${v},"prev":${p},"next":${n},"copy":${copy ? "true" : "false"}}`;
  return callJson("wasm_item_ok", payload, crypto);
}

export function browser_listing_ok_js(l) {
  return callJson("wasm_browser_listing_ok", JSON.stringify({ kind: l.kind, modes: l.modes, hosts: l.hosts }));
}

export function signer_of_js(lock, key) {
  return callJson("wasm_signer_of", `{"lock":${encodeLockView(lock)},"key":${JSON.stringify(key)}}`);
}

export function vault_supersedes_js(a, b) {
  let enc;
  try {
    enc = `{"a":${encodeStrict(a)},"b":${encodeStrict(b)}}`;
  } catch {
    return false;
  }
  const exp = ensureInit();
  inBytes = encoder.encode(enc);
  return exp.wasm_vault_supersedes() !== 0;
}

export function item_supersedes_js(a, b) {
  let enc;
  try {
    enc = `{"a":${encodeStrict(a)},"b":${encodeStrict(b)}}`;
  } catch {
    return false;
  }
  const exp = ensureInit();
  inBytes = encoder.encode(enc);
  return exp.wasm_item_supersedes() !== 0;
}

export function tie_of_js(parent, key, crypto) {
  return callStr("wasm_tie_of", JSON.stringify({ parent, key }), crypto);
}

export function fork_before_js(a, b) {
  return callJson("wasm_fork_before", JSON.stringify({
    a: { weight: a.weight, removal: a.removal === true, tie: a.tie, hash: a.hash },
    b: { weight: b.weight, removal: b.removal === true, tie: b.tie, hash: b.hash },
  }));
}

export function lock_chain_js(entries, genesis, votes, now, crypto) {
  let enc;
  try {
    enc = `{"entries":${encodeEntries(entries)},"genesis":${JSON.stringify(genesis)},"votes":${JSON.stringify(votes)},"now":${typeof now === "number" ? encodeStrict(now) : "null"}}`;
  } catch (e) {
    return { error: e instanceof NotLockValue ? e.message : String(e) };
  }
  const res = callJson("wasm_lock_chain", enc, crypto);
  if ("error" in res) return res;
  return { entries: res.at.map((i) => entries[i]), at: res.at, hashes: res.hashes, off: res.off };
}

export function person_chain_js(entries, genesis, crypto) {
  let enc;
  try {
    enc = `{"entries":${encodeEntries(entries)},"genesis":${JSON.stringify(genesis)}}`;
  } catch (e) {
    return { error: e instanceof NotLockValue ? e.message : String(e) };
  }
  const res = callJson("wasm_person_chain", enc, crypto);
  if ("error" in res) return res;
  return { entries: res.at.map((i) => entries[i]), at: res.at, hashes: res.hashes, off: res.off };
}

export function roster_js(ws, root, chains, bodies, without, crypto) {
  let enc;
  try {
    enc = `{"ws":${JSON.stringify(ws)},"root":${JSON.stringify(root)},"chains":${encodeChains(chains)},"bodies":${encodeBodies(bodies)},"without":${encodeTexts(without)}}`;
  } catch (e) {
    return { error: e instanceof NotLockValue ? e.message : String(e) };
  }
  return callJson("wasm_roster", enc, crypto);
}

export function carried_js(chain, crypto) {
  let enc;
  try {
    enc = `{"chain":${encodeEntries(chain)}}`;
  } catch (e) {
    enc = JSON.stringify({ invalid: e instanceof NotLockValue ? e.message : String(e) });
  }
  const exp = ensureInit();
  const prevCrypto = curCrypto;
  curCrypto = crypto;
  try {
    inBytes = encoder.encode(enc);
    const id = Number(exp.wasm_carried());
    return wrapCarriedHandle(id);
  } finally {
    curCrypto = prevCrypto;
  }
}

export function roster_carried_js(ws, h, chains, bodies, without, crypto) {
  let enc;
  try {
    enc = `{"ws":${JSON.stringify(ws)},"chains":${encodeChains(chains)},"bodies":${encodeBodies(bodies)},"without":${encodeTexts(without)}}`;
  } catch (e) {
    return { error: e instanceof NotLockValue ? e.message : String(e) };
  }
  return callJson("wasm_roster_carried", enc, crypto, h.__pion_carried_handle);
}

export function roster_moved_js(ws, chain, chains, bodies, without, crypto) {
  return roster_carried_js(ws, carried_js(chain, crypto), chains, bodies, without, crypto);
}

export function state4_js(ws, root, chains, bodies, now, crypto) {
  let enc;
  try {
    enc = `{"ws":${JSON.stringify(ws)},"root":${JSON.stringify(root)},"chains":${encodeChains(chains)},"bodies":${encodeBodies(bodies)},"now":${encodeStrict(now)}}`;
  } catch (e) {
    return { error: e instanceof NotLockValue ? e.message : String(e) };
  }
  return unwrapHeld(callJson("wasm_state4", enc, crypto));
}

export function state4_carried_js(ws, h, chains, bodies, now, crypto) {
  let enc;
  try {
    enc = `{"ws":${JSON.stringify(ws)},"chains":${encodeChains(chains)},"bodies":${encodeBodies(bodies)},"now":${encodeStrict(now)}}`;
  } catch (e) {
    return { error: e instanceof NotLockValue ? e.message : String(e) };
  }
  return unwrapHeld(callJson("wasm_state4_carried", enc, crypto, h.__pion_carried_handle));
}

export function state4_moved_js(ws, chain, chains, bodies, now, crypto) {
  return state4_carried_js(ws, carried_js(chain, crypto), chains, bodies, now, crypto);
}

export function bind_digest_js(ws, sub, log, moved, crypto) {
  return callJson("wasm_bind_digest", JSON.stringify({ ws, sub, log, moved }), crypto);
}

export function ws_tag_js(ws, genesis, crypto) {
  return callStr("wasm_ws_tag", JSON.stringify({ ws, genesis }), crypto);
}

export function body_hash_js(body, crypto) {
  let enc;
  try {
    enc = encodeStrict(body);
  } catch (e) {
    return "!" + (e instanceof NotLockValue ? e.message : String(e));
  }
  return callStr("wasm_body_hash", enc, crypto);
}

export function body_refusal_js(ws, body, commits, crypto) {
  let bodyEnc;
  try {
    bodyEnc = encodeStrict(body);
  } catch (e) {
    return `a body is {ws, kind, …, salt}: ${e instanceof NotLockValue ? e.message : String(e)}`;
  }
  let cs = "[";
  let first = true;
  for (let i = 0; i < commits.length; i++) {
    const x = commits[i];
    let chainEnc;
    try {
      chainEnc = encodeEntries(x.chain);
    } catch {
      continue;
    }
    if (!first) cs += ",";
    first = false;
    cs += `{"genesis":${JSON.stringify(x.genesis)},"chain":${chainEnc}}`;
  }
  cs += "]";
  return callJson("wasm_body_refusal", `{"ws":${JSON.stringify(ws)},"body":${bodyEnc},"commits":${cs}}`, crypto);
}
