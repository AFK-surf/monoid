// The features not yet everyone's are one registry, the core's (client/core-ts/src/features.ts `FEATURES`): the app
// keeps none of its own, reading what the core and the stations say, and the app's made-up core
// (apps/mbui/src/sffixture/fixture.mbt `fixture_experimental_features`) says the same experimental ids in the same order
// with the same `betaOnly`. Every id is read where the product decides by it (not a switch nothing reads), each the
// way its kind is decided: a station's (`station: true`) by the station's channel (`stationFeature`) and its overview
// (`station_feature`), the device's own by the prefs (`featureEnabled`, `feature_from`, …); no code asks for an id the
// registry no longer has (a feature graduated or dropped leaves no branch behind); each experimental one has its title
// and description in both catalogs, and the catalogs keep no words of one gone. Prints what is not so, and fails then.
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { FEATURES, type FeatureSpec } from "../client/core-ts/src/features.ts";

const root = execFileSync("git", ["rev-parse", "--show-toplevel"], { encoding: "utf8" }).trim();
const read = (file: string) => readFileSync(join(root, file), "utf8");
const faults: string[] = [];
const registry = FEATURES as Record<string, FeatureSpec>;
const ids = Object.keys(registry);

// 1. The made-up core's experimental features are the core's.
const FIXTURE = "apps/mbui/src/sffixture/fixture.mbt";
const block = /let fixture_experimental_features[^=]*=\s*\[([\s\S]*?)\n\]/.exec(read(FIXTURE));
if (block === null) faults.push(`${FIXTURE}: no fixture_experimental_features`);
else {
  const app = [...block[1]!.matchAll(/\(\s*"([^"]+)"\s*,\s*(true|false)\s*\)/g)].map((m) => ({ id: m[1]!, betaOnly: m[2] === "true" }));
  const core = ids.filter((id) => registry[id]!.stage === "experimental").map((id) => ({ id, betaOnly: registry[id]!.betaOnly === true }));
  if (JSON.stringify(app) !== JSON.stringify(core)) {
    faults.push(`${FIXTURE}'s fixture_experimental_features are not client/core-ts/src/features.ts's experimental FEATURES:\n  fixture: ${JSON.stringify(app)}\n  core:    ${JSON.stringify(core)}`);
  }
}

// The code the product is made of: TypeScript and MoonBit tracked, but tests, checks and the registries themselves.
const SKIP = /(^|\/)test\/|_wbtest\.mbt$|_test\.mbt$|\.test\.ts$|(^|\/)scripts\/features-check\.ts$|^client\/core-ts\/src\/features\.ts$|^apps\/mbui\/src\/sffixture\/|\/pkg\.generated\.mbti$|^apps\/mbui\/src\/sfrealsize\/|^apps\/mbui\/src\/sfkept\/|^apps\/mbui\/src\/sfapptest\//;
const files = execFileSync("git", ["ls-files", "-z", "--cached", "--others", "--exclude-standard", "*.ts", "*.mbt"], { cwd: root, encoding: "utf8" })
  .split("\0")
  .filter((f) => f !== "" && !f.startsWith("apps/mbui/deps/") && !f.includes("node_modules/") && !SKIP.test(f));

// 2. and 3. What asks for a feature by its id, and what it asks for.
const ASK = /\b(featureEnabled|stationFeature|featureOnChannel|station_feature|feature_on|feature_from|experimental_on|set_experimental)\(([^"()]*?)"([^"]+)"/g;
/// What asks for a feature the station decides; everything else asks for the device's own.
const STATION_ASKS = new Set(["stationFeature", "featureOnChannel", "station_feature"]);
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
    else if (STATION_ASKS.has(m[1]!) !== (registry[id]!.station === true)) faults.push(`${file}:${line}: ${m[1]}(… "${id}") asks ${registry[id]!.station === true ? "the device for a feature its station decides (station_feature, stationFeature)" : "a station for a feature of the device's own (feature_from, featureEnabled)"}`);
    asked.set(id, [...(asked.get(id) ?? []), `${file}:${line}`]);
  }
}
for (const id of ids) {
  if (!asked.has(id)) faults.push(`"${id}" is registered but nothing decides by it (no featureEnabled/stationFeature/station_feature/feature_on/feature_from of it outside tests): a switch that does nothing`);
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
