// What rules-bundle.test.ts bundles as a release's station/main.js is bundled (package.json build:node): the rules
// through shared/lock.ts and shared/rules-runtime.ts, walked on the entries in the file argv[2] names. It prints the
// walk (or what it threw), the rules' counters and how much rules.js itself copied and stepped meanwhile.
import { readFileSync } from "node:fs";
import * as lock from "../../shared/lock.ts";
import * as rules from "../../shared/rules-runtime.ts";
// @ts-ignore: the MoonBit build's JS, untyped
import * as mb from "../../rules/js/rules.js";
import { walk } from "./rules-walk.ts";

const copied = mb.copied_js(), stepped = mb.stepped_js();
let out: { walk: unknown } | { threw: string };
try {
  lock.bodyHash({ ws: "w", kind: "open", prev: null, salt: "s" });
  out = { walk: walk(rules as never, JSON.parse(readFileSync(process.argv[2]!, "utf8"))) };
} catch (e) {
  out = { threw: e instanceof Error ? e.message : String(e) };
}
console.log(JSON.stringify({ ...out, stats: rules.rulesShadowStats(), copied: mb.copied_js() - copied, stepped: mb.stepped_js() - stepped }));
