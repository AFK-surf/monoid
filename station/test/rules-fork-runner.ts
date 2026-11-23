// What rules-fork.test.ts and rules-fork-person-a.test.ts, -b and -c share: the seeds, the jobs a
// range of seeds makes, the worker pool of rules-fork-check.ts, and the sums and assertions over what came back. The
// person logs' drawn worlds are dealt to the three files by seed (`personSeedRanges`), each its own slice of
// check-station (scripts/station-slice.sh): one file of all of them took more than a slice's 5 minutes on CI's runners
// once the rules went through Pion by default (#8379). A world is seeded by its seed alone (rules-fork-check.ts), so
// how the seeds are dealt changes nothing of what is compared.
import assert from "node:assert/strict";
import { pool, print } from "./lock-fork-pool.ts";
import type { Job, More, Out } from "./rules-fork-check.ts";
import * as rules from "../../shared/rules-runtime.ts";

export const SEEDS = process.env.RULES_FORK_SEEDS === undefined ? null : Number(process.env.RULES_FORK_SEEDS);
export const LOCK_SEEDS = SEEDS ?? 32;
export const PERSON_SEEDS = SEEDS ?? 96;
export const STEPS = Number(process.env.RULES_FORK_STEPS ?? 120);
export const SCRIPTED = Number(process.env.RULES_FORK_SCRIPTED ?? 6);
/// Seeds a job: small enough that the threads share the work evenly.
export const BATCH = 6;
export const FAMILIES = ["free", "faults"] as const;

/// What the rules export for this, as rules/js/rules.js is built (without them, no world is run).
export const NEW = ["tie_of_js", "fork_before_js", "lock_chain_js", "person_chain_js", "person_fold_js", "roster_js", "state4_js", "roster_moved_js", "state4_moved_js", "ws_tag_js", "body_hash_js", "body_refusal_js"];
export const missing = NEW.filter((f) => typeof (rules as Record<string, unknown>)[f] !== "function");

/// The worker threads of rules-fork-check.ts, or none where the rules lack what they compare.
export const createRulesForkPool = () => (missing.length > 0 ? null : pool<Job>(new URL("./rules-fork-check.ts", import.meta.url), { rulesFork: true }));

/// The jobs of seeds `from` to `to` (both included; none where `from` is past `to`) of each variant and family.
export const seedJobs = (t: "lock" | "person", vs: Extract<Job, { t: "lock" | "person" }>["v"][], from: number, to: number): Job[] =>
  from > to
    ? []
    : vs.flatMap((v) => FAMILIES.flatMap((family) => Array.from({ length: Math.ceil((to - from + 1) / BATCH) }, (_, i) =>
        ({ t, v, family, from: from + i * BATCH, to: Math.min(to, from + (i + 1) * BATCH - 1), steps: STEPS }) as Job)));

/// The person logs' seeds `1..total` in three ranges, one a file (by default 1-32, 33-64, 65-96).
export const personSeedRanges = (total = PERSON_SEEDS): [number, number][] => {
  const c1 = Math.ceil(total / 3), c2 = Math.ceil((total * 2) / 3);
  return [[1, c1], [c1 + 1, c2], [c2 + 1, total]];
};

export const addMore = (a: More, b: More): More => {
  const refused = { ...a.refused };
  for (const [k, n] of Object.entries(b.refused)) refused[k] = (refused[k] ?? 0) + n;
  const out = { ...a, refused };
  for (const k of Object.keys(a) as (keyof More)[]) if (k !== "refused") (out[k] as number) = (a[k] as number) + (b[k] as number);
  return out;
};
export const none: More = { bodies: 0, refused: {}, inForce: 0, lacking: 0, lists: 0, states: 0, off: 0, notOn: 0, webs: 0, old: 0, moved: 0, afterMoved: 0, rolesOther: 0, admitted: 0, removals: 0, toldOut: 0, carried: 0 };
export const sum = (os: Out[]): Out => os.reduce((a, o) => ({
  worlds: a.worlds + o.worlds, checks: a.checks + o.checks, branched: a.branched + o.branched, refusedSeen: a.refusedSeen + o.refusedSeen,
  statements: a.statements + o.statements, differ: [...a.differ, ...o.differ], more: addMore(a.more, o.more),
}), { worlds: 0, checks: 0, branched: 0, refusedSeen: 0, statements: 0, differ: [], more: none });
export const said = (r: Record<string, number>) => Object.entries(r).map(([k, n]) => `${k}: ${n}`).join("; ") || "none";
export const told = (o: Out) => {
  const m = o.more;
  print(`  bodies offered ${m.bodies}, refused ${Object.values(m.refused).reduce((a, b) => a + b, 0)} (${said(m.refused)}); statements in force ${m.inForce}, entries lacking their body ${m.lacking}; lists ${m.lists}, states ${m.states} (off ${m.off}, not on ${m.notOn}); web devices ${m.webs}; old chains ${m.old}, moved ${m.moved}, an entry after it refused ${m.afterMoved}, chosen otherwise by votes by role ${m.rolesOther}; devices of a state let in by admit ${m.admitted}; removals compared ${m.removals}, holders a removal took out told ${m.toldOut}; states of a chain carried (D6) ${m.carried}`);
};

/// The person logs' drawn worlds of seeds `from` to `to` agree with the model, and were not trivial ones (where the
/// range has any seed: RULES_FORK_SEEDS=1 leaves the second and third files none).
export const assertPersonWorlds = (o: Out, variants: number, from: number, to: number) => {
  print(`person logs and a workspace, drawn, seeds ${from}-${to}: ${o.worlds} worlds (${variants} variants, fault-free and with faults; as drawn, one body held back for good, two workspaces), ${o.checks} chains compared, ${o.branched} children beaten, ${o.refusedSeen} entries refused, ${o.statements} statements' reasons; ${o.differ.length} differ`);
  told(o);
  for (const d of o.differ.slice(0, 3)) print(`  ${d.slice(0, 300)}`);
  assert.equal(o.differ.length, 0, "the rules and the model differ (the first are printed above)");
  if (from > to) return;
  // (forks came up and forgeries were refused, bodies were refused, some lacked, statements had reasons: not trivial worlds)
  const m = o.more;
  assert.ok(o.branched > 0 && o.refusedSeen > 0 && o.statements > 0 && Object.keys(m.refused).length > 0 && m.lacking > 0 && m.inForce > 0 && m.admitted > 0 && m.removals > 0 && m.toldOut > 0, `${o.branched} beaten, ${o.refusedSeen} refused, ${o.statements} statements, ${m.lacking} lacking, ${m.removals} removals, ${m.toldOut} told out`);
};

/// Under STILLFAIL_RULES_MODE shadow or pion, the worlds of `outs` went through it with no difference between the
/// ports (and some call did, where any world was run).
export const assertRulesModeUsed = (outs: Out[]) => {
  const here = rules.rulesShadowStats();
  const calls = here.calls + outs.reduce((n, o) => n + (o.rules?.calls ?? 0), 0);
  const mismatches = here.mismatches + outs.reduce((n, o) => n + (o.rules?.mismatches ?? 0), 0);
  print(`rules: ${here.mode}, ${calls} calls through it, ${mismatches} differ`);
  assert.equal(mismatches, 0, here.first ?? "a worker's rules differed (logged there)");
  if (here.mode !== "moonbit" && outs.length > 0) assert.ok(calls > 0, "no call went through the rules' mode");
};
