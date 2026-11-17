// What the core imports of the station's own files (client/core-ts's code and tests reach into station/ by a relative
// path) is what scripts/check.sh says a change to typechecks the core and runs its tests: each such file matches its
// core_station (the core's typecheck) and its core_test_paths (the core's tests, which scripts/plan.sh reads for CI's
// check-core), and is among core_test_inputs (what those tests are remembered by). #6720 changed
// station/src/sessions/presets.ts alone, which the core's test/presets-carried.test.ts imports: neither ran, and main
// was red at the next change to the core. Prints each import a list misses, and fails then.
//   node scripts/core-station.ts <core_station> <core_test_paths> <core_test_inputs>
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, join, normalize } from "node:path";

const [typecheck, tests, inputs] = process.argv.slice(2);
if (typecheck === undefined || tests === undefined || inputs === undefined) {
  console.log("usage: node scripts/core-station.ts <core_station> <core_test_paths> <core_test_inputs>");
  process.exit(2);
}
const root = execFileSync("git", ["rev-parse", "--show-toplevel"], { encoding: "utf8" }).trim();
const files = execFileSync("git", ["ls-files", "-z", "--", "client/core-ts"], { cwd: root, encoding: "utf8" })
  .split("\0")
  .filter((f) => /\.[cm]?[jt]sx?$/.test(f));
// (a static import or export's `from "…"`, an `import("…")`; only those that leave the core for station/)
const SPEC = /(?:\bfrom\s*|\bimport\s*\(\s*)["']((?:\.\.\/)+station\/[^"']+)["']/g;
const typechecked = new RegExp(typecheck);
const tested = new RegExp(tests);
const kept = inputs.split(/\s+/).filter((p) => p !== "");
const missed: string[] = [];
const seen = new Set<string>();
for (const file of files) {
  const text = readFileSync(join(root, file), "utf8");
  for (const m of text.matchAll(SPEC)) {
    const path = normalize(join(dirname(file), m[1]!));
    if (!path.startsWith("station/") || seen.has(path)) continue;
    seen.add(path);
    const lacks = [
      typechecked.test(path) ? null : "core_station",
      tested.test(path) ? null : "core_test_paths",
      kept.some((p) => path === p || path.startsWith(`${p}/`)) ? null : "core_test_inputs",
    ].filter((x) => x !== null);
    if (lacks.length > 0) missed.push(`${file}: imports ${path}, which scripts/check.sh's ${lacks.join(", ")} miss${lacks.length === 1 ? "es" : ""}`);
  }
}
if (missed.length > 0) {
  console.log(missed.join("\n"));
  console.log("(add each to core_station, core_test_paths and core_test_inputs in scripts/check.sh: a change to it alone must typecheck and test the core)");
  process.exit(1);
}
