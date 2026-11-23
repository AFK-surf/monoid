// One walk over the rules a station uses (rules-runtime.test.ts, and rules-bundle-entry.ts as a release runs it), on
// a moved workspace's entries as plain JSON, so a process of its own walks the same ones.
import { createHash } from "node:crypto";
import { endpointProof, sigValid, taggedSigValid, validKeyId } from "../../shared/lock.ts";
import type { World } from "./lock-moved-world.ts";

const crypto = { sha256Hex: (s: string) => createHash("sha256").update(s).digest("hex"), sigValid, validKeyId, endpointProof, taggedSigValid };
const NOW = 2_000_000;
export const plain = (v: unknown) => JSON.parse(JSON.stringify(v, (k, x) => (k === "rules" ? "<handle>" : x instanceof Map ? [...x] : x instanceof Set ? [...x] : x)));

/// What a walk reads of a world, its handover said.
export const walkOf = (w: World) => ({
  ws: w.ws, first: w.first, moved: w.moved,
  chains: [w.alice.entries, w.bob.entries, w.carol.entries],
  bodies: [w.alice, w.bob, w.carol].flatMap((l) => [...l.bodies.values()]),
  bobSigner: w.bob.app.signer.id, carolSigner: w.carol.app.signer.id, carolEndpoint: w.carol.app.base.hex,
  bobEntries: w.bob.entries,
});
export type Walked = ReturnType<typeof walkOf>;

/// A folded chain, an entry applied to it, who signs, a connection admitted, the chain's fork choice, and a moved
/// workspace read from its people's logs through `carried_js` (state4 and roster), each step taking the handles the
/// one before gave.
export function walk(r: Record<string, (...a: any[]) => any>, w: Walked) {
  const g = r.genesis_js(w.first, crypto);
  const moved = r.apply_js(g.rules, w.moved, NOW, crypto);
  const held = r.fold_held_js([w.first, w.moved], NOW, crypto);
  const h = r.carried_js([w.first, w.moved], crypto);
  const s4 = r.state4_carried_js(w.ws, h, w.chains, w.bodies, NOW, crypto);
  return {
    g: plain(g), moved: plain(moved), held: plain(held),
    signer: r.signer_js(held.rules, w.bobSigner, NOW),
    admit: r.admit_one_js(g.rules, { sub: "carol", endpoint: w.carolEndpoint }, NOW, crypto),
    chain: plain(r.lock_chain_js([w.moved, w.first], plain(g).state.genesis, "roles", null, crypto)),
    person: plain(r.person_fold_js(w.bobEntries, "bob", crypto)),
    s4: plain(s4),
    s4signer: r.signer_js(s4.rules, w.carolSigner, NOW),
    roster: plain(r.roster_carried_js(w.ws, h, w.chains, w.bodies, [], crypto)),
    moved4: plain(r.state4_moved_js(w.ws, [w.first, w.moved], w.chains, w.bodies, NOW, crypto)),
    canonical: r.canonical_of({ b: [1, "x"], a: null }),
  };
}
