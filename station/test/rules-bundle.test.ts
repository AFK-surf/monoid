// A release's rules (scripts/station-bundle.sh): shared/rules-runtime.ts bundled into station/main.js as
// `pnpm run build:node` bundles it, with pion/rules/js copied beside it as pion-rules/, in a directory away from the
// source tree, so nothing falls back to the checkout's pion/rules/js. Each STILLFAIL_RULES_MODE walks a moved
// workspace there as the source tree's rules do: shadow with no difference, pion with rules.js never stepping.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { cpSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";
import { fileURLToPath } from "node:url";
import { build, stop } from "esbuild";
import { rulesFor } from "../../shared/rules-runtime.ts";
import { handover, world } from "./lock-moved-world.ts";
import { walk, walkOf } from "./rules-walk.ts";

const ROOT = fileURLToPath(new URL("..", import.meta.url));
const REPO = fileURLToPath(new URL("../..", import.meta.url));
// (esbuild's service is a process of its own, ended with the file's tests)
after(() => stop());

const w = world();
handover(w);
const W = walkOf(w);

/// A release's station/ in a directory of its own: main.js as build:node bundles it (its banner and flags), and
/// pion-rules/ as station-bundle.sh copies it, unless `pion` is false.
async function release(pion: boolean) {
  // (its real path: what main.js finds itself at, macOS's /tmp being /private/tmp)
  const dir = realpathSync(mkdtempSync(join(tmpdir(), "rules-bundle-")));
  const station = join(dir, "stillfail", "station");
  mkdirSync(station, { recursive: true });
  const pkg = JSON.parse(readFileSync(join(ROOT, "package.json"), "utf8"));
  const banner = /--banner:js="(.*?)"/.exec(pkg.scripts["build:node"])![1]!;
  await build({
    absWorkingDir: ROOT, entryPoints: ["test/rules-bundle-entry.ts"], bundle: true, platform: "node", format: "esm",
    target: "node24", outfile: join(station, "main.js"), external: ["*.node"], banner: { js: banner }, logLevel: "silent",
  });
  writeFileSync(join(station, "package.json"), '{"type":"module"}\n');
  const bundleScript = readFileSync(join(REPO, "scripts", "station-bundle.sh"), "utf8");
  assert.match(bundleScript, /cp -R "\$root\/pion\/rules\/js\/\." "\$app\/station\/pion-rules\/"/, "station-bundle.sh copies pion/rules/js as pion-rules/");
  if (pion) cpSync(join(REPO, "pion", "rules", "js"), join(station, "pion-rules"), { recursive: true });
  writeFileSync(join(dir, "walk.json"), JSON.stringify(W));
  const run = (mode: string) => JSON.parse(execFileSync(process.execPath, [join(station, "main.js"), join(dir, "walk.json")], {
    cwd: dir, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"],
    env: { ...process.env, STILLFAIL_RULES_MODE: mode, STILLFAIL_RULES_SHADOW_STRICT: "1" },
  }));
  return { dir, station, run };
}

test("a release's main.js walks the rules alike in every mode, with the Pion port from pion-rules/ beside it", async () => {
  const ref = JSON.parse(JSON.stringify(walk(rulesFor("moonbit"), W)));
  const r = await release(true);
  try {
    const bundled = readFileSync(join(r.station, "main.js"), "utf8");
    assert.doesNotMatch(bundled, /pion_wasm_rt|createPionRuntime/, "the Pion port is loaded beside main.js, never bundled in it");
    const moonbit = r.run("moonbit");
    assert.deepEqual(moonbit.walk, ref, moonbit.threw);
    assert.deepEqual(moonbit.stats, { mode: "moonbit", calls: 0, mismatches: 0, first: null, pion: false });
    assert.ok(moonbit.stepped > 0, "rules.js answers in moonbit");

    const shadow = r.run("shadow");
    assert.deepEqual(shadow.walk, ref, shadow.threw);
    assert.equal(shadow.stats.mismatches, 0, shadow.stats.first ?? "");
    assert.ok(shadow.stats.pion && shadow.stats.calls >= 14, JSON.stringify(shadow.stats));

    const pion = r.run("pion");
    assert.deepEqual(pion.walk, ref, pion.threw);
    assert.deepEqual({ ...pion.stats, calls: 0 }, { mode: "pion", calls: 0, mismatches: 0, first: null, pion: true });
    assert.ok(pion.stats.calls >= 14, JSON.stringify(pion.stats));
    assert.deepEqual([pion.copied, pion.stepped], [0, 0], "rules.js copied and stepped nothing in pion");
  } finally {
    rmSync(r.dir, { recursive: true, force: true });
  }
});

test("a release without pion-rules/ runs moonbit, and says where it looked for the Pion port in shadow or pion", async () => {
  const r = await release(false);
  try {
    assert.equal(r.run("moonbit").stats.pion, false);
    for (const mode of ["shadow", "pion"]) {
      const got = r.run(mode);
      assert.ok("threw" in got, `${mode} fell back to a Pion port elsewhere: ${JSON.stringify(got.stats)}`);
      assert.match(got.threw, /the Pion rules \(STILLFAIL_RULES_MODE shadow or pion\) are at none of /);
      assert.ok(got.threw.includes(join(r.station, "pion-rules", "rules-wasm.mjs")), got.threw);
      assert.ok(got.threw.includes(join(r.dir, "stillfail", "pion", "rules", "js", "rules-wasm.mjs")), got.threw);
    }
  } finally {
    rmSync(r.dir, { recursive: true, force: true });
  }
});
