// The rules' fork choice, a person's log, a workspace's bodies, list and state (rules/src/lock/chain.mbt, person.mbt,
// body.mbt, roster.mbt, state4.mbt, lock.mbt's `moved`) against the models they were written from, on the worlds the
// models draw (rules-fork-check.ts says what is compared): the workspace lock's first rounds, and the fourth round's
// (lock-roster4-model.ts, 2026-11-13) under its defaults, whose person logs, drawn as round three's were, now carry
// commitments where round three's carried its statements in the clear. Nothing in the product calls these rules but
// the chains (src/cloud/log-keep.ts, 2026-11-12; lock-forks.test.ts holds a station to the model) and the person fold:
// this is what holds them to the design.
//
// RULES_FORK_SEEDS=<n> worlds a variant and family (by default 32 for the workspace lock, 96 for person logs: several
// hundred in all), RULES_FORK_STEPS=<n> steps a world (120), RULES_FORK_SCRIPTED=<n> seeds of the fourth round's
// scripted worlds (6). Worker threads as lock-fork-choice.test.ts (lock-fork-pool.ts). The person logs' drawn worlds
// are run by rules-fork-person-a.test.ts, -b and -c, a third of the seeds each (by default 1-32, 33-64 and 65-96: 384
// worlds in all), so that each of the four files takes a slice of check-station of its own (rules-fork-runner.ts).
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { test } from "node:test";
import { type Entry, endpointProof, entryHash, sigValid, taggedSigValid, validKeyId } from "../../shared/lock.ts";
import { key, signed } from "./lock-world-sim.ts";
import { VARIANTS } from "./lock-fork-choice-model.ts";
import { print } from "./lock-fork-pool.ts";
import type { Job, Out } from "./rules-fork-check.ts";
import { LOCK_SEEDS, SCRIPTED, assertRulesModeUsed, createRulesForkPool, missing, seedJobs, sum, told } from "./rules-fork-runner.ts";
import * as rules from "../../shared/rules-runtime.ts";

/// The workspace lock's variants the rules have: one vote a device or by role, the active chain or everything offered,
/// resigning or not; a removal of a device that signs, `tie=signer`.
const LOCK_V = VARIANTS.filter((v) => v.removal === "device" && v.hashfield === "as-is").map((v) => ({ ...v, tie: "signer" as const }));

const ask = createRulesForkPool();
const run = (js: Job[]) => (ask === null ? Promise.resolve([] as Out[]) : Promise.all(js.map((j) => ask<Out>(j))));
const lockOut = run(seedJobs("lock", LOCK_V, 1, LOCK_SEEDS));
const scriptedOut = run(Array.from({ length: SCRIPTED }, (_, i) => ({ t: "scripted", from: i + 1, to: i + 1 }) as Job));

test("the rules export the fork choice and the list", () => {
  assert.deepEqual(missing, [], "rules/js/rules.js lacks these: run rules/build.sh");
});

test("the rules' active chain of the workspace lock is every model keeper's, at each quarter of a world and at its end", async () => {
  assert.ok(ask !== null, "no rules to compare");
  const o = sum(await lockOut);
  print(`workspace lock: ${o.worlds} worlds (${LOCK_V.length} variants, fault-free and with faults), ${o.checks} chains compared, ${o.branched} children beaten, ${o.refusedSeen} entries refused; ${o.differ.length} differ`);
  for (const d of o.differ.slice(0, 3)) print(`  ${d.slice(0, 300)}`);
  assert.equal(o.differ.length, 0, "the rules and the model differ (the first are printed above)");
  // (branches came up, and forgeries were refused: the comparison was not of straight chains alone)
  assert.ok(o.branched > 0 && o.refusedSeen > 0, `${o.branched} beaten, ${o.refusedSeen} refused`);
});

test("the rules are the fourth round's model's on its scripted worlds: bodies no one's, web devices by a keeper's clock, a revoked key, off and on again, the handover, the handover that waits for nobody", async () => {
  assert.ok(ask !== null, "no rules to compare");
  const o = sum(await scriptedOut);
  print(`person logs and a workspace, scripted: ${o.worlds} seeds of M2, M5, a revoked key's web device and off, M6, M7's four rows, M8's seven, M9's cases, ${o.checks} chains compared, ${o.branched} children beaten, ${o.refusedSeen} entries refused, ${o.statements} statements' reasons; ${o.differ.length} differ`);
  told(o);
  for (const d of o.differ.slice(0, 3)) print(`  ${d.slice(0, 300)}`);
  assert.equal(o.differ.length, 0, "the rules and the model differ (the first are printed above)");
  const m = o.more;
  assert.ok(m.off > 0 && m.moved > 0 && m.carried > 0 && m.afterMoved === m.moved && m.webs > 0 && o.branched > 0 && Object.keys(m.refused).length >= 5, `off ${m.off}, moved ${m.moved}, after it refused ${m.afterMoved}, web devices ${m.webs}, ${o.branched} beaten, ${Object.keys(m.refused).length} reasons a body was refused`);
});

// A device has three keys: its base key (`id`), its key on its person's log (`key`, sealed for the person's presence:
// it signs that log alone) and the key it signs a workspace's things with, unasked (a vault's versions and box
// certificates; a workspace chain's entries), which its log's entries say as `sign_key` (client/core-ts/src/
// personal-lock.ts `Device`). The fold keeps the last said and every one said; a moved workspace's state names a
// device by it, never by the log's key (the lead, 2026-11-13: nothing the workspace signer signed checked out against
// the moved state).
test("a person's log says each device's signer: the fold keeps it and those said before, and a moved workspace's state names the device by it, never by its key on the log", () => {
  const crypto = { sha256Hex: (s: string) => createHash("sha256").update(s).digest("hex"), sigValid, validKeyId, endpointProof, taggedSigValid };
  const [log1, log2, log3] = [key(7101), key(7102), key(7103)];
  const [s1, s2a, s2b] = [key(7201), key(7202), key(7203)];
  const [id1, id2, id3] = [key(7301).hex, key(7302).hex, key(7303).hex];
  const chain: Entry[] = [];
  const add = (kind: string, body: unknown) => {
    const last = chain.at(-1);
    chain.push(signed({ v: 1, ws: "person:alice", seq: chain.length, prev: last ? entryHash(last) : null, at: 1_790_000_000, kind, body } as Omit<Entry, "sig">, log1));
  };
  add("genesis", { sub: "alice", device: { key: log1.id, id: id1, label: "app", sign_key: s1.id } });
  add("device", { key: log2.id, id: id2, label: "phone", sign_key: s2a.id });
  // (said again with another signer: that device's signer the one said now, the one before kept)
  add("device", { key: log2.id, id: id2, label: "phone", sign_key: s2b.id });
  // (one that says none, and one that says what is no ed25519 key id: none, never a refusal)
  add("device", { key: log3.id, id: id3, label: "old app" });
  const p = rules.person_fold_js(chain, "alice", crypto) as any;
  assert.ok(!("error" in p), JSON.stringify(p));
  const byId = new Map((p.devices as any[]).map((d) => [d.id, d]));
  assert.deepEqual([id1, id2, id3].map((id) => [byId.get(id)?.sign_key ?? null, byId.get(id)?.sign_keys]), [[s1.id, [s1.id]], [s2b.id, [s2a.id, s2b.id]], [null, []]], "the fold keeps each device's signer");
  const bad = [...chain];
  const last = bad.at(-1)!;
  bad.push(signed({ v: 1, ws: "person:alice", seq: bad.length, prev: entryHash(last), at: 1_790_000_000, kind: "device", body: { key: log3.id, id: id3, label: "old app", sign_key: "p256:x" } } as Omit<Entry, "sig">, log1));
  const q = rules.person_fold_js(bad, "alice", crypto) as any;
  assert.ok(!("error" in q), "a signer that is no key id is none, never a refusal");
  assert.equal((q.devices as any[]).find((d) => d.id === id3)?.sign_key, undefined);
  // The workspace said in alice's log (her `open`): its state names each app by its signer.
  const g = entryHash(chain[0]!);
  const open = { ws: "ws", kind: "open", origins: ["https://stillfail.test"], rp_id: "stillfail.test", cloud_keys: {}, email: "a@x.com", prev: null, salt: "77".repeat(16) };
  add("ws", { t: rules.ws_tag_js("ws", g, crypto), h: rules.body_hash_js(open, crypto) });
  const out = rules.state4_js("ws", g, [chain], [open], 1_790_000_100, crypto) as any;
  assert.equal(out.on, "on", JSON.stringify(out.error ?? out.on));
  const devs = new Map((out.state.devices as [string, any][]).map(([id, d]) => [id, d]));
  const keys = new Map(out.state.signKeys as [string, string[]][]);
  assert.deepEqual([id1, id2, id3].map((id) => [devs.get(id)?.kind, devs.get(id)?.sign_key ?? null, keys.get(id) ?? []]), [["app", s1.id, [s1.id]], ["app", s2b.id, [s2a.id, s2b.id]], ["app", null, []]], "named by its signer");
  const logKeys = new Set([log1.id, log2.id, log3.id]);
  assert.ok([...devs.values()].every((d) => !logKeys.has(d.sign_key)) && [...keys.values()].flat().every((k) => !logKeys.has(k)), "never by its key on the log");
  // The signer alone signs as the device: `signer_js` finds the app by it, and by its key on the log nothing.
  assert.equal(rules.signer_js(out.rules, s1.id, null)?.sub, "alice");
  assert.equal(rules.signer_js(out.rules, log1.id, null), null);
  assert.equal(rules.signer_js(out.rules, s2a.id, null), null, "a signer said before signs no more");
});

test("under STILLFAIL_RULES_MODE shadow or pion, the worlds above went through it, with no difference between the ports", async () => {
  assertRulesModeUsed([...await lockOut, ...await scriptedOut]);
});
