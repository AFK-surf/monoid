// The features not yet everyone's (client/core-ts/src/features.ts `FEATURES`) are one registry: the app's
// (apps/mbui/src/sfapp/settings/features.mbt `feature_registry`) says the same ids in the same order with the same stage
// and `betaOnly`; every id is read where the product decides by it (not a switch nothing reads); no code asks for an
// id the registry no longer has (a feature graduated or dropped leaves no branch behind); each experimental one has
// its title and description in both catalogs, and the catalogs keep no words of one gone. Prints what is not so, and
// fails then.
//   node scripts/features-check.ts
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { FEATURES, type FeatureSpec } from "../client/core-ts/src/features.ts";

const root = execFileSync("git", ["rev-parse", "--show-toplevel"], { encoding: "utf8" }).trim();
const read = (file: string) => readFileSync(join(root, file), "utf8");
const faults: string[] = [];
const registry = FEATURES as Record<string, FeatureSpec>;
const ids = Object.keys(registry);

// 1. The app's registry is the core's.
const MBT = "apps/mbui/src/sfapp/settings/features.mbt";
const block = /let feature_registry[^=]*=\s*\[([\s\S]*?)\n\]/.exec(read(MBT));
if (block === null) faults.push(`${MBT}: no feature_registry`);
else {
  const app = [...block[1]!.matchAll(/\(\s*"([^"]+)"\s*,\s*"([^"]+)"\s*,\s*(true|false)\s*\)/g)].map((m) => ({ id: m[1]!, stage: m[2]!, betaOnly: m[3] === "true" }));
  const core = ids.map((id) => ({ id, stage: registry[id]!.stage, betaOnly: registry[id]!.betaOnly === true }));
  if (JSON.stringify(app) !== JSON.stringify(core)) {
    faults.push(`${MBT}'s feature_registry is not client/core-ts/src/features.ts's FEATURES:\n  app:  ${JSON.stringify(app)}\n  core: ${JSON.stringify(core)}`);
  }
}

// The code the product is made of: TypeScript and MoonBit tracked, but tests, checks and the registries themselves.
const SKIP = /(^|\/)test\/|_wbtest\.mbt$|_test\.mbt$|\.test\.ts$|(^|\/)scripts\/features-check\.ts$|^client\/core-ts\/src\/features\.ts$|^apps\/mbui\/src\/sfapp\/settings\/features\.mbt$|^apps\/mbui\/src\/sffixture\/|\/pkg\.generated\.mbti$|^apps\/mbui\/src\/sfrealsize\/|^apps\/mbui\/src\/sfkept\//;
const files = execFileSync("git", ["ls-files", "-z", "--cached", "--others", "--exclude-standard", "*.ts", "*.mbt"], { cwd: root, encoding: "utf8" })
  .split("\0")
  .filter((f) => f !== "" && !f.startsWith("apps/mbui/deps/") && !f.includes("node_modules/") && !SKIP.test(f));

// 2. and 3. What asks for a feature by its id, and what it asks for.
const ASK = /\b(featureEnabled|stationFeature|feature_on|feature_from|experimental_on|experimental_from|set_experimental)\(([^"()]*?)"([^"]+)"/g;
const asked = new Map<string, string[]>();
for (const file of files) {
  let text: string;
  try {
    text = read(file);
  } catch {
    continue;
  }
  for (const m of text.matchAll(ASK)) {
    const id = m[3]!;
    const line = text.slice(0, m.index).split("\n").length;
    if (!(id in registry)) faults.push(`${file}:${line}: ${m[1]}(… "${id}") asks for a feature the registry does not have (graduated or dropped: take the branch out)`);
    asked.set(id, [...(asked.get(id) ?? []), `${file}:${line}`]);
  }
}
for (const id of ids) {
  if (!asked.has(id)) faults.push(`"${id}" is registered but nothing decides by it (no featureEnabled/stationFeature/feature_on/feature_from of it outside tests): a switch that does nothing`);
}

// 4. Each experimental one's words in both catalogs, none of one gone.
for (const lang of ["zh", "en"]) {
  const file = `client/i18n/catalog/${lang}/web-pages.json`;
  const words = JSON.parse(read(file)) as Record<string, string>;
  for (const id of ids.filter((i) => registry[i]!.stage === "experimental")) {
    for (const part of ["title", "description"]) {
      if (!(`web-pages.experimental.${id}.${part}` in words)) faults.push(`${file}: web-pages.experimental.${id}.${part} missing`);
    }
  }
  for (const key of Object.keys(words)) {
    const m = /^web-pages\.experimental\.([^.]+)\.[^.]+$/.exec(key);
    if (m !== null && !(m[1]! in registry && registry[m[1]!]!.stage === "experimental")) faults.push(`${file}: ${key} is of no experimental feature registered`);
  }
}

if (faults.length) {
  for (const f of faults) console.error(f);
  process.exit(1);
}
console.log(`features: ${ids.length} registered, each decided by: ${ids.map((id) => `${id} (${asked.get(id)!.length})`).join(", ")}`);
