// shared/rules-runtime.ts: the rules by STILLFAIL_RULES_MODE. moonbit is rules/js/rules.js's own functions; shadow
// answers by them and holds the Pion port's answers to them, handles paired across calls; pion calls rules.js never.
// The station's lock and vault suites run under each mode as well (station/AGENTS.md, Tests).
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { test } from "node:test";
import { endpointProof, sigValid, taggedSigValid, validKeyId } from "../../shared/lock.ts";
import { RULES_FUNCTIONS, rulesFor } from "../../shared/rules-runtime.ts";
import { handover, world } from "./lock-moved-world.ts";
// @ts-ignore: the MoonBit build's JS, untyped
import * as mb from "../../rules/js/rules.js";

const crypto = { sha256Hex: (s: string) => createHash("sha256").update(s).digest("hex"), sigValid, validKeyId, endpointProof, taggedSigValid };
const NOW = 2_000_000;
const plain = (v: unknown) => JSON.parse(JSON.stringify(v, (k, x) => (k === "rules" ? "<handle>" : x instanceof Map ? [...x] : x instanceof Set ? [...x] : x)));

/// A moved workspace, its handover said (keys drawn per run: every mode walks the same one).
const W = world();
handover(W);

/// One walk over the rules a station uses, each step taking the handles the one before gave: a folded chain, an entry
/// applied to it, who signs, a connection admitted, the chain's fork choice, and a moved workspace read from its
/// people's logs through `carried_js` (state4 and roster).
function walk(r: Record<string, (...a: any[]) => any>, w: ReturnType<typeof world>) {
  const g = r.genesis_js(w.first, crypto);
  const moved = r.apply_js(g.rules, w.moved, NOW, crypto);
  const held = r.fold_held_js([w.first, w.moved], NOW, crypto);
  const chains = [w.alice.entries, w.bob.entries, w.carol.entries];
  const bodies = [w.alice, w.bob, w.carol].flatMap((l) => [...l.bodies.values()]);
  const h = r.carried_js([w.first, w.moved], crypto);
  const s4 = r.state4_carried_js(w.ws, h, chains, bodies, NOW, crypto);
  return {
    g: plain(g), moved: plain(moved), held: plain(held),
    signer: r.signer_js(held.rules, w.bob.app.signer.id, NOW),
    admit: r.admit_one_js(g.rules, { sub: "carol", endpoint: w.carol.app.base.hex }, NOW, crypto),
    chain: plain(r.lock_chain_js([w.moved, w.first], plain(g).state.genesis, "roles", null, crypto)),
    person: plain(r.person_fold_js(w.bob.entries, "bob", crypto)),
    s4: plain(s4),
    s4signer: r.signer_js(s4.rules, w.carol.app.signer.id, NOW),
    roster: plain(r.roster_carried_js(w.ws, h, chains, bodies, [], crypto)),
    moved4: plain(r.state4_moved_js(w.ws, [w.first, w.moved], chains, bodies, NOW, crypto)),
    canonical: r.canonical_of({ b: [1, "x"], a: null }),
  };
}

test("moonbit is rules.js's own functions, the Pion port never loaded for it", () => {
  const r = rulesFor("moonbit");
  for (const name of RULES_FUNCTIONS) assert.equal(r[name], (mb as any)[name], name);
  assert.deepEqual(Object.keys(mb).sort(), [...RULES_FUNCTIONS].sort(), "rules-runtime lists every function rules.js exports");
  const out = execFileSync(process.execPath, ["--input-type=module", "-e",
    `const r = await import(${JSON.stringify(new URL("../../shared/rules-runtime.ts", import.meta.url).href)}); r.canonical_of({a:1}); console.log(JSON.stringify(r.rulesShadowStats()))`],
  { env: { ...process.env, STILLFAIL_RULES_MODE: "" }, encoding: "utf8" });
  assert.deepEqual(JSON.parse(out), { mode: "moonbit", calls: 0, mismatches: 0, first: null, pion: false });
});

test("shadow answers as moonbit, with the Pion port asked every call and no difference, handles paired across calls", () => {
  const ref = walk(rulesFor("moonbit"), W);
  const r = rulesFor("shadow", true);
  assert.deepEqual(walk(r, W), ref);
  const s = r.stats();
  assert.equal(s.mismatches, 0, s.first ?? "");
  assert.ok(s.calls >= 13 && s.pion, JSON.stringify(s));
  assert.ok(ref.s4.on === "on" && ref.roster.members.length === 3, "the moved workspace is read whole");
});

test("pion answers as moonbit without calling rules.js", () => {
  const ref = walk(rulesFor("moonbit"), W);
  const r = rulesFor("pion");
  const copied = mb.copied_js(), stepped = mb.stepped_js();
  const got = walk(r, W);
  assert.equal(mb.copied_js(), copied, "rules.js copied no state");
  assert.equal(mb.stepped_js(), stepped, "rules.js stepped no entry");
  assert.deepEqual(got, ref);
  assert.ok(r.stats().calls >= 13);
});

test("a difference is logged and moonbit's answer kept, or thrown when strict", () => {
  const port = () => ({ ...(mb as any), lower_role: () => "viewer", carried_js: () => { throw new Error("no port"); } });
  const lines: string[] = [];
  const loose = rulesFor("shadow", false, (l) => lines.push(l), port);
  assert.equal(loose.lower_role("owner", "member"), mb.lower_role("owner", "member"));
  assert.equal(loose.canonical_of({ a: 1 }), '{"a":1}');
  const w = world();
  const h = loose.carried_js([w.first, w.moved], crypto);
  assert.equal(typeof h, "object");
  assert.deepEqual(loose.stats().mismatches, 2);
  assert.match(lines[0]!, /"event":"rules_shadow_mismatch","fn":"lower_role"/);
  assert.match(lines[1]!, /"fn":"carried_js".*no port/);
  const strict = rulesFor("shadow", true, () => assert.fail("strict throws, not logs"), port);
  assert.throws(() => strict.lower_role("owner", "member"), /lower_role differs between MoonBit and Pion/);
});

test("STILLFAIL_RULES_MODE routes shared/lock.ts, and anything else is refused", () => {
  const src = `const l = await import(${JSON.stringify(new URL("../../shared/lock.ts", import.meta.url).href)});
    const r = await import(${JSON.stringify(new URL("../../shared/rules-runtime.ts", import.meta.url).href)});
    l.bodyHash({ ws: "w", kind: "open", prev: null, salt: "s" }); console.log(JSON.stringify(r.rulesShadowStats()))`;
  const of = (mode: string) => JSON.parse(execFileSync(process.execPath, ["--input-type=module", "-e", src],
    { env: { ...process.env, STILLFAIL_RULES_MODE: mode, STILLFAIL_RULES_SHADOW_STRICT: "1" }, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }));
  assert.deepEqual(of("moonbit"), { mode: "moonbit", calls: 0, mismatches: 0, first: null, pion: false });
  assert.deepEqual(of("shadow"), { mode: "shadow", calls: 1, mismatches: 0, first: null, pion: true });
  assert.deepEqual(of("pion"), { mode: "pion", calls: 1, mismatches: 0, first: null, pion: true });
  assert.throws(() => of("wasm"), /STILLFAIL_RULES_MODE is moonbit, shadow or pion/);
});
