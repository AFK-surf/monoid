// The first third of the person logs' drawn worlds that rules-fork.test.ts holds the rules to (by default seeds 1-32),
// a file of its own so that it takes a slice of check-station of its own (rules-fork-runner.ts says why).
import assert from "node:assert/strict";
import { test } from "node:test";
import { V3 } from "./lock-roster-model.ts";
import type { Out } from "./rules-fork-check.ts";
import { assertPersonWorlds, assertRulesModeUsed, createRulesForkPool, personSeedRanges, seedJobs, sum } from "./rules-fork-runner.ts";

const ask = createRulesForkPool();
const [from, to] = personSeedRanges()[0]!;
const out = ask === null ? Promise.resolve([] as Out[]) : Promise.all(seedJobs("person", V3, from, to).map((j) => ask<Out>(j)));

test("the rules' person logs, bodies, lists and states are the fourth round's model's on its drawn worlds of this third of the seeds", async () => {
  assert.ok(ask !== null, "no rules to compare");
  assertPersonWorlds(sum(await out), V3.length, from, to);
});

test("under STILLFAIL_RULES_MODE shadow or pion, this third's worlds went through it, with no difference between the ports", async () => {
  assertRulesModeUsed(await out);
});
