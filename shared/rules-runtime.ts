// The lock's and vault's rules as the station and the cloud call them (shared/lock.ts, station/src/vault/crypto.ts):
// the MoonBit build (rules/js/rules.js) or its Pion port (pion/rules/js/rules-wasm.mjs), by STILLFAIL_RULES_MODE.
//   moonbit (default, and anywhere without process.env): rules.js's own functions, nothing in between.
//   shadow: rules.js answers; the Pion port is asked the same and every answer compared (canonical JSON, a thrown
//     error's message, whether a handle came back). A difference is logged, or thrown with
//     STILLFAIL_RULES_SHADOW_STRICT=1 (tests). Handles (a state's `rules`, `carried_js`'s) are pairs of both.
//   pion: the Pion port alone; rules.js is never called.
// The Pion port is loaded only in Node and only in shadow or pion, synchronously by require(esm): a Worker (cloud/)
// or the default mode never reads a file, draws a random value or bundles it. The core (client/core-ts, in Hermes,
// which has no WebAssembly) keeps importing rules/js/rules.js itself.
// @ts-ignore: the MoonBit build's JS, untyped
import * as mb from "../rules/js/rules.js";

export type RulesMode = "moonbit" | "shadow" | "pion";
/// `calls`: through shadow or Pion; `mismatches`: answers that differed (`first` the first, as logged); `pion`: whether
/// the Pion port was loaded in this process.
export type RulesStats = { mode: RulesMode; calls: number; mismatches: number; first: string | null; pion: boolean };
type Fn = (...args: any[]) => any;
type Rules = Record<(typeof RULES_FUNCTIONS)[number], Fn>;

/// Every function rules/js/rules.js exports, in its order.
export const RULES_FUNCTIONS = [
  "canonical_of", "entry_text_of", "lower_role", "fold_js", "admit_js", "genesis_js", "apply_js", "signer_js",
  "admit_one_js", "copied_js", "stepped_js", "fold_held_js", "person_fold_js", "admit_person_js", "cert_ok_js",
  "vault_ok_js", "item_ok_js", "browser_listing_ok_js", "signer_of_js", "vault_supersedes_js", "item_supersedes_js",
  "tie_of_js", "fork_before_js", "lock_chain_js", "person_chain_js", "roster_js", "carried_js", "roster_carried_js",
  "roster_moved_js", "state4_js", "state4_carried_js", "state4_moved_js", "bind_digest_js", "ws_tag_js",
  "body_hash_js", "body_refusal_js",
] as const;

/// Counters of each implementation's own work (tests count them), not answers: never compared.
const OWN = new Set<string>(["copied_js", "stepped_js"]);

const env = (k: string): string | undefined =>
  typeof process !== "undefined" && process.env !== undefined ? process.env[k] : undefined;

function modeOf(v: string | undefined): RulesMode {
  if (v === undefined || v === "" || v === "moonbit") return "moonbit";
  if (v === "shadow" || v === "pion") return v;
  throw new Error(`STILLFAIL_RULES_MODE is moonbit, shadow or pion, not ${JSON.stringify(v)}`);
}

let pionLoaded: Rules | null = null;
/// The Pion port, loaded once on first use (Node only).
function pion(): Rules {
  if (pionLoaded !== null) return pionLoaded;
  const getBuiltin = typeof process !== "undefined" ? (process as any).getBuiltinModule : undefined;
  if (typeof getBuiltin !== "function") throw new Error("the Pion rules are loaded only in Node");
  const { createRequire } = getBuiltin("node:module");
  const { fileURLToPath } = getBuiltin("node:url");
  const path = fileURLToPath(new URL("../pion/rules/js/rules-wasm.mjs", import.meta.url));
  pionLoaded = createRequire(import.meta.url)(path) as Rules;
  return pionLoaded;
}

/// A value as it is compared: object keys sorted, undefined fields dropped, Maps and Sets as their entries, a state's
/// handle (`rules`, top level) as a mark that one came back.
function plain(v: unknown, top: boolean): unknown {
  if (v === null || typeof v !== "object") return typeof v === "number" && Object.is(v, -0) ? 0 : v;
  if (v instanceof Map) return { $map: [...v].map(([k, x]) => [plain(k, false), plain(x, false)]) };
  if (v instanceof Set) return { $set: [...v].map((x) => plain(x, false)) };
  if (Array.isArray(v)) return v.map((x) => plain(x, false));
  const out: Record<string, unknown> = {};
  for (const k of Object.keys(v).sort()) {
    const x = (v as Record<string, unknown>)[k];
    if (x === undefined) continue;
    out[k] = top && k === "rules" ? "<handle>" : plain(x, false);
  }
  return out;
}

type Outcome = { ok: true; value: unknown } | { ok: false; error: unknown };
const run = (f: Fn, args: unknown[]): Outcome => {
  try {
    return { ok: true, value: f(...args) };
  } catch (error) {
    return { ok: false, error };
  }
};
const said = (o: Outcome): string => {
  if (!o.ok) return JSON.stringify({ threw: o.error instanceof Error ? o.error.message : String(o.error) });
  const v = o.value;
  if (typeof v === "number" && !Number.isFinite(v)) return JSON.stringify({ number: String(v) });
  return JSON.stringify(plain(v, true)) ?? "undefined";
};

const CUT = 400;
const cut = (s: string) => (s.length > CUT ? `${s.slice(0, CUT)}…(${s.length})` : s);

/// The rules for one mode, with their counters. The module's own exports are `rulesFor(STILLFAIL_RULES_MODE)`'s; tests
/// make the others side by side, and may stand another `port` in for the Pion one.
export function rulesFor(mode: RulesMode, strict = false, warn: (line: string) => void = (l) => console.warn(l), port: () => Rules = pion): Rules & { stats(): RulesStats } {
  const stats = { mode, calls: 0, mismatches: 0, first: null as string | null };
  const statsOf = (): RulesStats => ({ ...stats, pion: pionLoaded !== null });
  const api = {} as Rules;
  if (mode === "moonbit") {
    for (const name of RULES_FUNCTIONS) api[name] = (mb as Rules)[name];
    return Object.assign(api, { stats: statsOf });
  }
  if (mode === "pion") {
    for (const name of RULES_FUNCTIONS) {
      api[name] = (...args: unknown[]) => {
        stats.calls++;
        return port()[name](...args);
      };
    }
    return Object.assign(api, { stats: statsOf });
  }

  // shadow: each handle given out is a pair of both implementations'.
  const pairs = new WeakMap<object, { mb: unknown; pi: unknown }>();
  const pairOf = (mbH: unknown, piH: unknown): object => {
    const h = Object.freeze({});
    pairs.set(h, { mb: mbH, pi: piH });
    return h;
  };
  const side = (a: unknown, which: "mb" | "pi") => {
    const p = a !== null && typeof a === "object" ? pairs.get(a) : undefined;
    return p === undefined ? a : p[which];
  };
  const differ = (name: string, why: string) => {
    stats.mismatches++;
    const line = JSON.stringify({ event: "rules_shadow_mismatch", fn: name, why: cut(why) });
    if (stats.first === null) stats.first = line;
    if (strict) throw new Error(`rules shadow: ${name} differs between MoonBit and Pion: ${cut(why)}`);
    warn(line);
  };
  for (const name of RULES_FUNCTIONS) {
    api[name] = (...args: unknown[]) => {
      stats.calls++;
      const a = run((mb as Rules)[name], args.map((x) => side(x, "mb")));
      let p: Outcome;
      try {
        p = run(port()[name], args.map((x) => side(x, "pi")));
      } catch (error) {
        p = { ok: false, error };
      }
      if (OWN.has(name)) {
        if (!a.ok) throw a.error;
        return a.value;
      }
      if (name === "carried_js") {
        // Opaque on both sides: compared by what the calls taking it answer.
        if (!a.ok) throw a.error;
        if (!p.ok) {
          differ(name, `pion threw ${said(p)}`);
          return pairOf(a.value, undefined);
        }
        return pairOf(a.value, p.value);
      }
      const sa = said(a), sp = said(p);
      if (sa !== sp) differ(name, `moonbit ${sa} pion ${sp}`);
      if (!a.ok) throw a.error;
      const v = a.value as any;
      if (v !== null && typeof v === "object" && !Array.isArray(v) && "rules" in v) {
        const pv = p.ok ? (p.value as any) : undefined;
        return { ...v, rules: pairOf(v.rules, pv !== null && typeof pv === "object" ? pv.rules : undefined) };
      }
      return v;
    };
  }
  return Object.assign(api, { stats: statsOf });
}

const own = rulesFor(modeOf(env("STILLFAIL_RULES_MODE")), env("STILLFAIL_RULES_SHADOW_STRICT") === "1");

/// What this process's rules did: its mode, the calls through shadow or Pion, the differences found (the first of them).
export const rulesShadowStats = (): RulesStats => own.stats();

export const canonical_of = own.canonical_of;
export const entry_text_of = own.entry_text_of;
export const lower_role = own.lower_role;
export const fold_js = own.fold_js;
export const admit_js = own.admit_js;
export const genesis_js = own.genesis_js;
export const apply_js = own.apply_js;
export const signer_js = own.signer_js;
export const admit_one_js = own.admit_one_js;
export const copied_js = own.copied_js;
export const stepped_js = own.stepped_js;
export const fold_held_js = own.fold_held_js;
export const person_fold_js = own.person_fold_js;
export const admit_person_js = own.admit_person_js;
export const cert_ok_js = own.cert_ok_js;
export const vault_ok_js = own.vault_ok_js;
export const item_ok_js = own.item_ok_js;
export const browser_listing_ok_js = own.browser_listing_ok_js;
export const signer_of_js = own.signer_of_js;
export const vault_supersedes_js = own.vault_supersedes_js;
export const item_supersedes_js = own.item_supersedes_js;
export const tie_of_js = own.tie_of_js;
export const fork_before_js = own.fork_before_js;
export const lock_chain_js = own.lock_chain_js;
export const person_chain_js = own.person_chain_js;
export const roster_js = own.roster_js;
export const carried_js = own.carried_js;
export const roster_carried_js = own.roster_carried_js;
export const roster_moved_js = own.roster_moved_js;
export const state4_js = own.state4_js;
export const state4_carried_js = own.state4_carried_js;
export const state4_moved_js = own.state4_moved_js;
export const bind_digest_js = own.bind_digest_js;
export const ws_tag_js = own.ws_tag_js;
export const body_hash_js = own.body_hash_js;
export const body_refusal_js = own.body_refusal_js;
